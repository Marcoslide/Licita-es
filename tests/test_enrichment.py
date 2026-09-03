from __future__ import annotations

import sqlite3
import tempfile
import unittest
from pathlib import Path

from bolsa_licitacoes.enrichment import DouSearch, HealthPriceIndex


class EnrichmentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.path = Path(self.tempdir.name) / "health.db"
        with sqlite3.connect(self.path) as connection:
            connection.executescript(
                """
                create table metadata (key text primary key, value text not null);
                create table bps_prices (
                  id integer primary key, source_year integer, institution_name text,
                  institution_cnpj text, institution_sphere text, city text, state_code text,
                  purchase_date text, inserted_date text, modality text, purchase_type text,
                  catmat_code text, description text, description_key text, unit text,
                  unit_capacity text, generic_flag text, anvisa_registration text,
                  supplier_cnpj text, supplier_name text, manufacturer_cnpj text,
                  manufacturer_name text, quantity real, unit_price real, total_price real,
                  source_url text
                );
                create table cmed_prices (
                  id integer primary key, published_at text, substance text, substance_key text,
                  company_cnpj text, laboratory text, ggrem_code text, registration text, ean text,
                  product text, product_key text, presentation text, therapeutic_class text,
                  product_type text, price_regime text, pf_no_tax real, pf_zero real,
                  pf_eighteen real, pmvg_no_tax real, pmvg_zero real, pmvg_eighteen real,
                  hospital_restriction text, cap text, confaz_87 text, tax_credit_list text,
                  commercialization text, label text, source_url text
                );
                insert into metadata values ('bps_records','2');
                insert into bps_prices (
                  source_year,institution_name,city,state_code,purchase_date,catmat_code,
                  description,description_key,unit,anvisa_registration,supplier_name,
                  quantity,unit_price,total_price,source_url
                ) values
                  (2025,'Hospital A','Belo Horizonte','MG','2025-04-01','12345',
                   'Ceftriaxona 1 g','ceftriaxona 1 g','FRASCO-AMPOLA','100012345','Fornecedor A',10,5,50,'bps'),
                  (2026,'Hospital B','Contagem','MG','2026-02-01','12345',
                   'Ceftriaxona 1 g','ceftriaxona 1 g','FRASCO-AMPOLA','100012345','Fornecedor B',10,7,70,'bps');
                insert into cmed_prices (
                  published_at,substance,substance_key,laboratory,registration,product,product_key,
                  presentation,pmvg_no_tax,pmvg_eighteen,cap,source_url
                ) values ('11/08/2026','CEFTRIAXONA','ceftriaxona','Laboratório X','100012345',
                  'CEFTRIAXONA X','ceftriaxona x','1 G PO INJ CT FA',8,10,'SIM','cmed');
                """
            )

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def test_catmat_keeps_unit_and_links_cmed_by_anvisa_registration(self) -> None:
        result = HealthPriceIndex(self.path).enrich([{
            "item_number": 1, "description": "Ceftriaxona 1 g",
            "catalog_item_code": "12345", "unit": "FRASCO-AMPOLA",
        }], "MG")
        self.assertTrue(result["available"])
        self.assertEqual(1, result["matched_items"])
        item = result["items"][0]
        self.assertEqual("CATMAT exato", item["bps"]["match_method"])
        self.assertEqual(6, item["bps"]["median"])
        self.assertEqual("100012345", item["cmed"]["presentations"][0]["registration"])

    def test_missing_index_fails_explicitly(self) -> None:
        result = HealthPriceIndex(Path(self.tempdir.name) / "missing.db").enrich([])
        self.assertFalse(result["available"])

    def test_dou_score_requires_context_beyond_process_number(self) -> None:
        procurement = {"organization_name": "Prefeitura de Guaraciaba", "city_name": "Guaraciaba", "object": "medicamentos hospitalares"}
        strong = DouSearch._score({"title": "Aviso", "content": "Prefeitura de Guaraciaba compra medicamentos hospitalares"}, procurement)
        weak = DouSearch._score({"title": "Aviso", "content": "Processo de outra entidade"}, procurement)
        self.assertGreaterEqual(strong["match_score"], 90)
        self.assertLess(weak["match_score"], 45)


if __name__ == "__main__":
    unittest.main()
