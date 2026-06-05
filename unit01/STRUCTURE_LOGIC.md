# Präzise Dateilogik für das Minimalprojekt

Die Minimalstruktur orientiert sich an dem vorhandenen ZIP. Sie trennt Quellen, Medien, Stildefinitionen und Ausgabe. `docs/` ist bewusst nicht Bestandteil dieses Quellpakets, weil es Render-Output ist.

```text
topoclimate/
├── _quarto.yml
├── index.qmd
├── unit01/
│   └── L01_fieldclim_datenbasis_und_station.qmd
├── images/
│   ├── 01-splash.jpg
│   └── figures/
│       ├── fig00_kurslogik.svg
│       ├── fig01_station_object.svg
│       └── fig02_datenrollen_energie.svg
├── css/
│   ├── styles.css
│   ├── theme-dark.scss
│   ├── banner-style.html
│   └── banner-footer.html
├── assets/
│   └── geoinfo.bib
├── STYLE_GUIDE.md
├── STRUCTURE_LOGIC.md
└── README.md
```

`_quarto.yml` ist die einzige Stelle für Website-Logik: Renderpfade, Sidebar, Footer-Includes, globale HTML-Optionen und Navigation. Kursseiten verlinken intern immer auf `.qmd`, nie auf `.html` und nie auf `docs/`.

`index.qmd` ist die Kursstartseite. Sie darf einen anderen Bannerpfad nutzen als die Sitzungen, bleibt aber normale Quarto-Website-Seite. Sie führt in Kurslogik, Arbeitsverständnis und Seitenfolge ein.

`unit01/` enthält die Kursseiten. Neue Seiten folgen dem Muster `L02_...qmd`, `L03_...qmd` usw. Jede neue Seite muss in `_quarto.yml` in die Sidebar eingetragen werden, wenn sie in der Navigation erscheinen soll.

`images/figures/` enthält Kursabbildungen im gemeinsamen Infografikstil. SVG ist bevorzugt, weil Text und Linien scharf bleiben und die Dateien versionierbar sind. PNG ist möglich, wenn eine Grafik aus einem externen Grafiksystem stammt.

`css/` enthält globale Gestaltung. Seiten sollen keine eigene CSS-Datei setzen, außer es gibt einen klaren Grund. Kleine Ergänzungen für Reader-Elemente können in `css/styles.css` ergänzt werden.

`assets/` enthält Bibliographie und weitere projektweite Ressourcen. Aus `unit01/*.qmd` wird die Bibliographie mit `../assets/geoinfo.bib` referenziert.
