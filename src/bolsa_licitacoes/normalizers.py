from __future__ import annotations

import sqlite3
from typing import Any, Mapping, Optional

from .db import Database, utcnow


def normalize_procurement(
    db: Database,
    *,
    source_id: int,
    raw_id: int,
    payload: Mapping[str, Any],
    source_url: str,
    flavor: str,
) -> int:
    if flavor == "pncp":
        org_data = payload.get("orgaoEntidade") or {}
        unit_data = payload.get("unidadeOrgao") or {}
        control = payload.get("numeroControlePNCP")
        fields = {
            "year": payload.get("anoCompra"), "sequence": payload.get("sequencialCompra"),
            "purchase_number": payload.get("numeroCompra"), "process_number": payload.get("processo"),
            "object": payload.get("objetoCompra"), "modality_id": payload.get("modalidadeId"),
            "modality_name": payload.get("modalidadeNome"), "dispute_mode_id": payload.get("modoDisputaId"),
            "status_id": payload.get("situacaoCompraId"), "status_name": payload.get("situacaoCompraNome"),
            "proposal_start": payload.get("dataAberturaProposta"), "proposal_end": payload.get("dataEncerramentoProposta"),
            "estimated_value": payload.get("valorTotalEstimado"), "homologated_value": payload.get("valorTotalHomologado"),
            "source_created_at": payload.get("dataInclusao"), "source_updated_at": payload.get("dataAtualizacaoGlobal") or payload.get("dataAtualizacao"),
            "external_id": control,
        }
        tax_id, legal_name = org_data.get("cnpj"), org_data.get("razaoSocial")
        level, branch = org_data.get("esferaId"), org_data.get("poderId")
        unit_code, unit_name = unit_data.get("codigoUnidade"), unit_data.get("nomeUnidade")
        state_code, state_name = unit_data.get("ufSigla"), unit_data.get("ufNome")
        city_code, city_name = unit_data.get("codigoIbge"), unit_data.get("municipioNome")
    else:
        control = payload.get("numeroControlePNCP")
        fields = {
            "year": payload.get("anoCompraPncp"), "sequence": payload.get("sequencialCompraPncp"),
            "purchase_number": payload.get("numeroCompra"), "process_number": payload.get("processo"),
            "object": payload.get("objetoCompra"), "modality_id": payload.get("modalidadeIdPncp"),
            "modality_name": payload.get("modalidadeNome"), "dispute_mode_id": payload.get("modoDisputaIdPncp"),
            "status_id": payload.get("situacaoCompraIdPncp"), "status_name": payload.get("situacaoCompraNomePncp"),
            "proposal_start": payload.get("dataAberturaPropostaPncp"), "proposal_end": payload.get("dataEncerramentoPropostaPncp"),
            "estimated_value": payload.get("valorTotalEstimado"), "homologated_value": payload.get("valorTotalHomologado"),
            "source_created_at": payload.get("dataInclusaoPncp"), "source_updated_at": payload.get("dataAtualizacaoPncp") or payload.get("dataAualizacaoPncp"),
            "external_id": payload.get("idCompra") or control,
        }
        tax_id, legal_name = payload.get("orgaoEntidadeCnpj"), payload.get("orgaoEntidadeRazaoSocial")
        level, branch = payload.get("orgaoEntidadeEsferaId"), payload.get("orgaoEntidadePoderId")
        unit_code, unit_name = payload.get("unidadeOrgaoCodigoUnidade"), payload.get("unidadeOrgaoNomeUnidade")
        state_code, state_name = payload.get("unidadeOrgaoUfSigla"), None
        city_code, city_name = payload.get("unidadeOrgaoCodigoIbge"), payload.get("unidadeOrgaoMunicipioNome")

    if not control:
        raise ValueError("Contratação sem numeroControlePNCP")

    with db.connect() as conn:
        state_id = _upsert_state(conn, state_code, state_name, source_id, raw_id, source_url)
        city_id = _upsert_city(conn, city_code, city_name, state_id, source_id, raw_id, source_url)
        org_id = _upsert_org(conn, tax_id, legal_name, level, branch, source_id, raw_id, source_url)
        unit_id = _upsert_unit(conn, org_id, unit_code, unit_name, state_id, city_id, source_id, raw_id, source_url)
        conn.execute(
            "INSERT INTO procurements(pncp_control_number,organization_id,purchasing_unit_id,year,sequence,"
            "purchase_number,process_number,object,modality_id,modality_name,dispute_mode_id,status_id,status_name,"
            "proposal_start,proposal_end,estimated_value,homologated_value,source_system,source_id,source_external_id,"
            "source_url,raw_record_id,source_created_at,source_updated_at,collected_at,confidence) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1.0) "
            "ON CONFLICT(pncp_control_number) DO UPDATE SET organization_id=excluded.organization_id,"
            "purchasing_unit_id=excluded.purchasing_unit_id,object=COALESCE(excluded.object,procurements.object),"
            "status_id=excluded.status_id,status_name=excluded.status_name,proposal_start=excluded.proposal_start,"
            "proposal_end=excluded.proposal_end,estimated_value=excluded.estimated_value,"
            "homologated_value=excluded.homologated_value,source_updated_at=excluded.source_updated_at,"
            "collected_at=excluded.collected_at",
            (control, org_id, unit_id, fields["year"], fields["sequence"], fields["purchase_number"],
             fields["process_number"], fields["object"], fields["modality_id"], fields["modality_name"],
             fields["dispute_mode_id"], fields["status_id"], fields["status_name"], fields["proposal_start"],
             fields["proposal_end"], fields["estimated_value"], fields["homologated_value"], flavor, source_id,
             fields["external_id"], source_url, raw_id, fields["source_created_at"], fields["source_updated_at"], utcnow()),
        )
        procurement_id = int(conn.execute("SELECT id FROM procurements WHERE pncp_control_number=?", (control,)).fetchone()[0])
        _source_link(conn, "procurement", procurement_id, source_id, str(fields["external_id"]), source_url, raw_id)
    db.mark_processed(raw_id)
    return procurement_id


def normalize_item(db: Database, *, source_id: int, raw_id: int, procurement_id: int, payload: Mapping[str, Any], source_url: str) -> int:
    number = payload.get("numeroItem") or payload.get("numeroItemCompra")
    if number is None:
        raise ValueError("Item sem numeroItem")
    with db.connect() as conn:
        conn.execute(
            "INSERT INTO procurement_items(procurement_id,item_number,description,material_or_service,quantity,unit,"
            "estimated_unit_value,estimated_total_value,status_id,status_name,has_result,catalog_item_code,source_id,"
            "source_external_id,source_url,raw_record_id,source_created_at,source_updated_at,collected_at,confidence) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1.0) ON CONFLICT(procurement_id,item_number) DO UPDATE SET "
            "description=excluded.description,quantity=excluded.quantity,unit=excluded.unit,"
            "estimated_unit_value=excluded.estimated_unit_value,estimated_total_value=excluded.estimated_total_value,"
            "status_id=excluded.status_id,status_name=excluded.status_name,has_result=excluded.has_result,"
            "raw_record_id=excluded.raw_record_id,source_updated_at=excluded.source_updated_at,collected_at=excluded.collected_at",
            (procurement_id, number, payload.get("descricao"), payload.get("materialOuServico"), payload.get("quantidade"),
             payload.get("unidadeMedida"), payload.get("valorUnitarioEstimado"), payload.get("valorTotal"),
             payload.get("situacaoCompraItem") or payload.get("situacaoCompraItemId"), payload.get("situacaoCompraItemNome"),
             int(bool(payload.get("temResultado"))), payload.get("catalogoCodigoItem"), source_id,
             f"{procurement_id}:{number}", source_url, raw_id, payload.get("dataInclusao"), payload.get("dataAtualizacao"), utcnow()),
        )
        item_id = int(conn.execute("SELECT id FROM procurement_items WHERE procurement_id=? AND item_number=?", (procurement_id, number)).fetchone()[0])
        _source_link(conn, "procurement_item", item_id, source_id, f"{procurement_id}:{number}", source_url, raw_id)
    db.mark_processed(raw_id)
    return item_id


def normalize_result(db: Database, *, source_id: int, raw_id: int, item_id: int, payload: Mapping[str, Any], source_url: str) -> int:
    seq = payload.get("sequencialResultado") or payload.get("sequencialResultadoItem") or 1
    tax_id = payload.get("niFornecedor") or payload.get("fornecedorCnpjCpf")
    name = payload.get("nomeRazaoSocialFornecedor") or payload.get("fornecedorNome")
    with db.connect() as conn:
        supplier_id = None
        if tax_id:
            conn.execute(
                "INSERT INTO suppliers(tax_id,name,size_id,country_code,source_id,source_external_id,source_url,raw_record_id,collected_at) "
                "VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(tax_id) DO UPDATE SET name=COALESCE(excluded.name,suppliers.name),collected_at=excluded.collected_at",
                (tax_id, name, payload.get("porteFornecedorId"), payload.get("codigoPais"), source_id, tax_id, source_url, raw_id, utcnow()),
            )
            supplier_id = int(conn.execute("SELECT id FROM suppliers WHERE tax_id=?", (tax_id,)).fetchone()[0])
        conn.execute(
            "INSERT INTO procurement_results(procurement_item_id,result_sequence,supplier_id,quantity,unit_value,total_value,brand,"
            "status_id,status_name,result_date,source_id,source_external_id,source_url,raw_record_id,source_created_at,source_updated_at,collected_at) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(procurement_item_id,result_sequence) DO UPDATE SET "
            "supplier_id=excluded.supplier_id,quantity=excluded.quantity,unit_value=excluded.unit_value,total_value=excluded.total_value,"
            "brand=excluded.brand,status_id=excluded.status_id,status_name=excluded.status_name,raw_record_id=excluded.raw_record_id,collected_at=excluded.collected_at",
            (item_id, seq, supplier_id, payload.get("quantidadeHomologada"), payload.get("valorUnitarioHomologado"),
             payload.get("valorTotalHomologado"), payload.get("marcaFabricante"), payload.get("situacaoCompraItemResultadoId"),
             payload.get("situacaoCompraItemResultadoNome"), payload.get("dataResultado"), source_id, f"{item_id}:{seq}",
             source_url, raw_id, payload.get("dataInclusao"), payload.get("dataAtualizacao"), utcnow()),
        )
        result_id = int(conn.execute("SELECT id FROM procurement_results WHERE procurement_item_id=? AND result_sequence=?", (item_id, seq)).fetchone()[0])
        _source_link(conn, "procurement_result", result_id, source_id, f"{item_id}:{seq}", source_url, raw_id)
    db.mark_processed(raw_id)
    return result_id


def _upsert_state(conn: sqlite3.Connection, code: Any, name: Any, source_id: int, raw_id: int, url: str) -> Optional[int]:
    if not code:
        return None
    conn.execute("INSERT INTO states(code,name,source_id,source_external_id,source_url,raw_record_id,collected_at) VALUES (?,?,?,?,?,?,?) ON CONFLICT(code) DO UPDATE SET name=COALESCE(excluded.name,states.name)", (str(code), name, source_id, str(code), url, raw_id, utcnow()))
    return int(conn.execute("SELECT id FROM states WHERE code=?", (str(code),)).fetchone()[0])


def _upsert_city(conn: sqlite3.Connection, code: Any, name: Any, state_id: Optional[int], source_id: int, raw_id: int, url: str) -> Optional[int]:
    if not code:
        return None
    conn.execute("INSERT INTO cities(ibge_code,name,state_id,source_id,source_external_id,source_url,raw_record_id,collected_at) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(ibge_code) DO UPDATE SET name=COALESCE(excluded.name,cities.name),state_id=COALESCE(excluded.state_id,cities.state_id)", (str(code), name, state_id, source_id, str(code), url, raw_id, utcnow()))
    return int(conn.execute("SELECT id FROM cities WHERE ibge_code=?", (str(code),)).fetchone()[0])


def _upsert_org(conn: sqlite3.Connection, tax_id: Any, name: Any, level: Any, branch: Any, source_id: int, raw_id: int, url: str) -> Optional[int]:
    if not tax_id:
        return None
    conn.execute("INSERT INTO organizations(tax_id,legal_name,government_level,government_branch,source_id,source_external_id,source_url,raw_record_id,collected_at) VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(tax_id) DO UPDATE SET legal_name=COALESCE(excluded.legal_name,organizations.legal_name),government_level=COALESCE(excluded.government_level,organizations.government_level),government_branch=COALESCE(excluded.government_branch,organizations.government_branch),collected_at=excluded.collected_at", (str(tax_id), name, level, branch, source_id, str(tax_id), url, raw_id, utcnow()))
    return int(conn.execute("SELECT id FROM organizations WHERE tax_id=?", (str(tax_id),)).fetchone()[0])


def _upsert_unit(conn: sqlite3.Connection, org_id: Optional[int], code: Any, name: Any, state_id: Optional[int], city_id: Optional[int], source_id: int, raw_id: int, url: str) -> Optional[int]:
    if not org_id or code is None:
        return None
    conn.execute("INSERT INTO purchasing_units(organization_id,code,name,state_id,city_id,source_id,source_external_id,source_url,raw_record_id,collected_at) VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(organization_id,code) DO UPDATE SET name=COALESCE(excluded.name,purchasing_units.name),state_id=COALESCE(excluded.state_id,purchasing_units.state_id),city_id=COALESCE(excluded.city_id,purchasing_units.city_id),collected_at=excluded.collected_at", (org_id, str(code), name, state_id, city_id, source_id, f"{org_id}:{code}", url, raw_id, utcnow()))
    return int(conn.execute("SELECT id FROM purchasing_units WHERE organization_id=? AND code=?", (org_id, str(code))).fetchone()[0])


def _source_link(conn: sqlite3.Connection, entity_type: str, entity_id: int, source_id: int, external_id: str, url: str, raw_id: int) -> None:
    conn.execute("INSERT OR IGNORE INTO source_links(entity_type,entity_id,source_id,source_external_id,source_url,raw_record_id) VALUES (?,?,?,?,?,?)", (entity_type, entity_id, source_id, external_id, url, raw_id))
