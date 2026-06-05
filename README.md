# Summer in the City — Seiten-Refactor

Dieses Paket enthält eine überarbeitete Struktur für die vier Quarto-Seiten:

- `pages/lehrerhandreichung_inhaltlich.qmd`
- `pages/schuelerseite_lst_stadtklima.qmd`
- `pages/lehrerhandreichung_technisch.qmd`
- `pages/konfigurator_lst_paket.qmd`

Zusätzlich enthalten:

- bestehende und neue Infografiken unter `images/figures/`
- Dummy-Downloadpaket unter `downloads/lst_materialpaket_koeln_demo.zip`
- aktuelles R-Skript unter `scripts/`, falls im Ausgangsmaterial vorhanden
- `ARCHITECTURE_PLAN.md` als verbindliche Seitenlogik

Die Pfade in den QMD-Dateien gehen davon aus, dass die Seiten in einem Unterordner `pages/` liegen und Bilder über `../images/figures/` erreicht werden.
