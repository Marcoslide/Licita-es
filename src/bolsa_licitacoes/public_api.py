from __future__ import annotations

from typing import Any, Mapping, Optional

from .db import Database


def market_summary(db: Database) -> dict[str, Any]:
    with db.connect() as conn:
        row = conn.execute(
            "SELECT COUNT(*) AS procurements,"
            "COALESCE(SUM(CASE WHEN estimated_value > 0 THEN estimated_value ELSE 0 END),0) AS estimated_value,"
            "COUNT(DISTINCT organization_id) AS organizations,"
            "COUNT(DISTINCT purchasing_unit_id) AS purchasing_units,"
            "MAX(collected_at) AS last_collected_at FROM procurements"
        ).fetchone()
        counts = {
            table: int(conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])
            for table in ("procurement_items", "procurement_results", "contracts", "suppliers", "documents")
        }
        states = int(conn.execute(
            "SELECT COUNT(DISTINCT u.state_id) FROM procurements p "
            "JOIN purchasing_units u ON u.id=p.purchasing_unit_id WHERE u.state_id IS NOT NULL"
        ).fetchone()[0])
        latest_run = conn.execute(
            "SELECT r.status,r.finished_at,r.records_seen,r.records_new,r.records_updated,r.errors,s.slug AS source_slug "
            "FROM source_runs r JOIN sources s ON s.id=r.source_id "
            "WHERE r.finished_at IS NOT NULL ORDER BY r.id DESC LIMIT 1"
        ).fetchone()
    return {
        "procurements": int(row["procurements"]),
        "estimated_value": float(row["estimated_value"] or 0),
        "organizations": int(row["organizations"]),
        "purchasing_units": int(row["purchasing_units"]),
        "states": states,
        "items": counts["procurement_items"],
        "results": counts["procurement_results"],
        "contracts": counts["contracts"],
        "suppliers": counts["suppliers"],
        "documents": counts["documents"],
        "last_collected_at": row["last_collected_at"],
        "latest_run": dict(latest_run) if latest_run else None,
    }


def state_summary(db: Database) -> list[dict[str, Any]]:
    with db.connect() as conn:
        rows = [dict(row) for row in conn.execute(
            "SELECT st.code,COALESCE(st.name,st.code) AS name,COUNT(DISTINCT p.id) AS procurements,"
            "COALESCE(SUM(CASE WHEN p.estimated_value > 0 THEN p.estimated_value ELSE 0 END),0) AS estimated_value,"
            "COUNT(DISTINCT p.organization_id) AS organizations,COUNT(DISTINCT u.city_id) AS cities,"
            "MAX(p.collected_at) AS last_collected_at "
            "FROM procurements p JOIN purchasing_units u ON u.id=p.purchasing_unit_id "
            "JOIN states st ON st.id=u.state_id GROUP BY st.id,st.code,st.name "
            "ORDER BY estimated_value DESC,procurements DESC"
        )]
        top_org_rows = [dict(row) for row in conn.execute(
            "SELECT state_code,legal_name,procurements,estimated_value FROM ("
            "SELECT st.code AS state_code,o.legal_name,COUNT(DISTINCT p.id) AS procurements,"
            "COALESCE(SUM(CASE WHEN p.estimated_value > 0 THEN p.estimated_value ELSE 0 END),0) AS estimated_value,"
            "ROW_NUMBER() OVER(PARTITION BY st.code ORDER BY COUNT(DISTINCT p.id) DESC,"
            "SUM(CASE WHEN p.estimated_value > 0 THEN p.estimated_value ELSE 0 END) DESC) AS rank "
            "FROM procurements p JOIN purchasing_units u ON u.id=p.purchasing_unit_id "
            "JOIN states st ON st.id=u.state_id LEFT JOIN organizations o ON o.id=p.organization_id "
            "GROUP BY st.code,o.id,o.legal_name) WHERE rank<=3 ORDER BY state_code,rank"
        )]
    by_state: dict[str, list[dict[str, Any]]] = {}
    for item in top_org_rows:
        by_state.setdefault(str(item.pop("state_code")), []).append(item)
    for row in rows:
        row["procurements"] = int(row["procurements"])
        row["estimated_value"] = float(row["estimated_value"] or 0)
        row["organizations"] = int(row["organizations"])
        row["cities"] = int(row["cities"])
        row["top_organizations"] = by_state.get(str(row["code"]), [])
    return rows


def list_procurements(db: Database, query: Mapping[str, list[str]]) -> dict[str, Any]:
    limit = _bounded_int(_first(query, "limit"), default=25, minimum=1, maximum=100)
    offset = _bounded_int(_first(query, "offset"), default=0, minimum=0, maximum=100_000)
    uf = (_first(query, "uf") or "").strip().upper()
    text = (_first(query, "q") or "").strip()
    source = (_first(query, "source") or "").strip().lower()
    sort = (_first(query, "sort") or "recent").strip().lower()
    period = (_first(query, "period") or "").strip().lower()
    status = (_first(query, "status") or "").strip().lower()

    where: list[str] = []
    params: list[Any] = []
    if uf:
        where.append("st.code=?")
        params.append(uf)
    if source:
        where.append("LOWER(p.source_system)=?")
        params.append(source)
    if text:
        pattern = f"%{text}%"
        where.append("(p.object LIKE ? OR p.pncp_control_number LIKE ? OR p.process_number LIKE ? OR o.legal_name LIKE ?)")
        params.extend((pattern, pattern, pattern, pattern))
    if period == "today":
        where.append("DATE(COALESCE(p.source_created_at,p.collected_at))=DATE('now')")
    elif period in {"7", "30", "365"}:
        where.append("DATE(COALESCE(p.source_created_at,p.collected_at))>=DATE('now',?)")
        params.append(f"-{int(period)} days")
    if status == "open":
        where.append("(p.proposal_end IS NULL OR DATETIME(p.proposal_end)>=DATETIME('now'))")
    elif status == "published_today":
        where.append("DATE(COALESCE(p.source_created_at,p.collected_at))=DATE('now')")
    elif status == "results":
        where.append("EXISTS(SELECT 1 FROM procurement_items pi JOIN procurement_results pr ON pr.procurement_item_id=pi.id WHERE pi.procurement_id=p.id)")
    elif status == "contracts":
        where.append("EXISTS(SELECT 1 FROM contracts ct WHERE ct.procurement_id=p.id)")
    elif status == "failed":
        where.append("(LOWER(COALESCE(p.status_name,'')) LIKE '%desert%' OR LOWER(COALESCE(p.status_name,'')) LIKE '%fracass%')")
    predicate = f"WHERE {' AND '.join(where)}" if where else ""
    order = {
        "value": "CASE WHEN p.estimated_value IS NULL THEN 1 ELSE 0 END,p.estimated_value DESC,p.id DESC",
        "deadline": "CASE WHEN p.proposal_end IS NULL THEN 1 ELSE 0 END,p.proposal_end ASC,p.id DESC",
        "recent": "COALESCE(p.source_created_at,p.collected_at) DESC,p.id DESC",
    }.get(sort, "COALESCE(p.source_created_at,p.collected_at) DESC,p.id DESC")
    joins = (
        "FROM procurements p LEFT JOIN organizations o ON o.id=p.organization_id "
        "LEFT JOIN purchasing_units u ON u.id=p.purchasing_unit_id "
        "LEFT JOIN states st ON st.id=u.state_id LEFT JOIN cities ci ON ci.id=u.city_id "
    )
    select = (
        "SELECT p.id,p.pncp_control_number,p.purchase_number,p.process_number,p.object,p.modality_name,"
        "p.status_name,p.proposal_start,p.proposal_end,p.estimated_value,p.homologated_value,p.source_system,"
        "p.source_url,p.source_created_at,p.source_updated_at,p.collected_at,o.legal_name AS organization_name,"
        "u.name AS purchasing_unit_name,st.code AS state_code,ci.name AS city_name,"
        "(SELECT COUNT(*) FROM procurement_items i WHERE i.procurement_id=p.id) AS items_count,"
        "(SELECT COUNT(*) FROM documents d WHERE d.procurement_id=p.id) AS documents_count "
    )
    with db.connect() as conn:
        total = int(conn.execute(f"SELECT COUNT(*) {joins}{predicate}", params).fetchone()[0])
        rows = [dict(row) for row in conn.execute(
            f"{select}{joins}{predicate} ORDER BY {order} LIMIT ? OFFSET ?", (*params, limit, offset)
        )]
    return {"total": total, "limit": limit, "offset": offset, "items": rows}


def procurement_detail(db: Database, procurement_id: int) -> Optional[dict[str, Any]]:
    with db.connect() as conn:
        row = conn.execute(
            "SELECT p.*,o.legal_name AS organization_name,u.name AS purchasing_unit_name,"
            "st.code AS state_code,ci.name AS city_name FROM procurements p "
            "LEFT JOIN organizations o ON o.id=p.organization_id "
            "LEFT JOIN purchasing_units u ON u.id=p.purchasing_unit_id "
            "LEFT JOIN states st ON st.id=u.state_id LEFT JOIN cities ci ON ci.id=u.city_id WHERE p.id=?",
            (procurement_id,),
        ).fetchone()
        if not row:
            return None
        items = [dict(item) for item in conn.execute(
            "SELECT id,item_number,description,material_or_service,quantity,unit,estimated_unit_value,"
            "estimated_total_value,status_name,has_result,catalog_item_code FROM procurement_items "
            "WHERE procurement_id=? ORDER BY item_number", (procurement_id,)
        )]
        documents = [dict(item) for item in conn.execute(
            "SELECT id,original_name,document_type,source_download_url,published_at,download_status,current_version "
            "FROM documents WHERE procurement_id=? ORDER BY id", (procurement_id,)
        )]
        sources = [dict(item) for item in conn.execute(
            "SELECT s.nome,s.slug,l.source_url,l.collected_at FROM source_links l "
            "JOIN sources s ON s.id=l.source_id WHERE l.entity_type='procurement' AND l.entity_id=? ORDER BY s.nome",
            (procurement_id,),
        )]
        contracts = [dict(item) for item in conn.execute(
            "SELECT id,pncp_control_number,contract_number,object,initial_value,current_value,signed_at,"
            "validity_start,validity_end FROM contracts WHERE procurement_id=? ORDER BY id", (procurement_id,)
        )]
    return {"procurement": dict(row), "items": items, "documents": documents, "sources": sources, "contracts": contracts}


def source_status(db: Database) -> list[dict[str, Any]]:
    with db.connect() as conn:
        return [dict(row) for row in conn.execute(
            "SELECT s.nome,s.slug,s.status,s.ultima_tentativa,s.ultima_coleta_sucesso,s.quantidade_registros,"
            "s.quantidade_erros,r.status AS last_run_status,r.records_seen AS last_records_seen,"
            "r.records_new AS last_records_new,r.finished_at AS last_finished_at "
            "FROM sources s LEFT JOIN source_runs r ON r.id=(SELECT id FROM source_runs "
            "WHERE source_id=s.id ORDER BY id DESC LIMIT 1) ORDER BY s.nome"
        )]


def _first(query: Mapping[str, list[str]], key: str) -> Optional[str]:
    values = query.get(key)
    return values[0] if values else None


def _bounded_int(value: Optional[str], *, default: int, minimum: int, maximum: int) -> int:
    try:
        parsed = int(value) if value is not None else default
    except (TypeError, ValueError):
        parsed = default
    return max(minimum, min(maximum, parsed))
