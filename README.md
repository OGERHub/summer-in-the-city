# Oberflächentemperaturen in der Stadt

Dieses Materialpaket unterstützt eine Unterrichtseinheit zur Analyse städtischer Oberflächentemperaturen mit Satellitendaten. Im Zentrum steht der Vergleich zwischen sichtbaren Stadtoberflächen im Luftbild und gemessenen bzw. abgeleiteten Land Surface Temperatures (LST).

Die Lernenden arbeiten zunächst analog mit einem Luftbild, Stadtbezirksgrenzen und transparenter Folie. Sie markieren Gebäude, Straßen, Parks, Wasserflächen, offene Böden oder andere erkennbare Oberflächen. Anschließend wird dieselbe Folie auf eine LST-Karte gelegt. Dadurch wird sichtbar, welche Oberflächen eher heiß oder eher kühl erscheinen und welche räumlichen Muster daraus entstehen.

Die Einheit verfolgt drei fachliche Ziele:

1. Oberflächen und Nutzungen im Luftbild qualitativ erkennen.
2. Oberflächentemperaturen aus Karte und Legende quantitativ zuordnen.
3. Räumlich-geographische Muster mit Prozessen wie Versiegelung, Verdunstung, Schatten, Wasserflächen und Bebauungsdichte erklären.

Das Paket enthält eine deutschsprachige Lehrerhandreichung im Quarto-Format, Infografiken, eine Beschreibung des Daten- und Unterrichtsworkflows sowie Hinweise zur digitalen Erweiterung in QGIS.

## Inhalte

- `lehrerhandreichung_lst_stadtklima.qmd`  
  Hauptdokument der Lehrerhandreichung.

- `figures/`  
  Infografiken zur Projektidee, LST, Lernzielen, Material-Temperatur-Zuordnung, Kartenschichten und technischem Workflow.

- `infografik_plan.md`  
  Übersicht über die verwendeten Abbildungen und deren Funktion.

- `package_manifest.json`  
  Technische Übersicht über die Paketstruktur.

## Grundidee

Die Unterrichtseinheit ist so angelegt, dass die fachliche Sachaufgabe vor der GIS-Technik steht. Die Lernenden sollen zunächst selbst Hypothesen aus dem Luftbild entwickeln und diese danach mit der LST-Karte prüfen.

Die digitale QGIS-Variante dient der Vorbereitung, dem Ausdruck und der Erweiterung für fortgeschrittene Gruppen. Sie ersetzt nicht die analoge Kartenarbeit, sondern macht dieselbe Layer-Logik technisch nachvollziehbar.

## Zielgruppe

Das Material richtet sich an Lehrkräfte und Lerngruppen ohne vorausgesetzte GIS-Erfahrung. Technische Hinweise zur Datenverarbeitung, Landsat-LST, AOI-Struktur, Hot-/Cold-Selektion und QGIS-Projektaufbau befinden sich im Appendix der Handreichung.

## Einstieg

Die Handreichung kann mit Quarto gerendert werden:

```bash
quarto render lehrerhandreichung_lst_stadtklima.qmd
```

## Autorin und Lizenz

Autorin: Jun.-Prof. Dr. Rieke Ammoneit  
Arbeitsbereich: Juniorprofessorin für Geographiedidaktik mit dem Schwerpunkt Physische Geographie  
Institution: Institut für Geographiedidaktik, Universität zu Köln

Dieses Materialpaket steht, sofern nicht anders angegeben, unter der Lizenz:

**Creative Commons Namensnennung 4.0 International (CC BY 4.0)**

Das bedeutet: Das Material darf geteilt, weiterverwendet und bearbeitet werden, sofern die Autorin genannt wird.

Empfohlene Zitierweise:

> Ammoneit, R. (2026). *Oberflächentemperaturen in der Stadt: Lehrerhandreichung zur analogen und digitalen Arbeit mit Luftbild, Folie und LST-Karten*. Institut für Geographiedidaktik, Universität zu Köln. Lizenz: CC BY 4.0.

Lizenztext: https://creativecommons.org/licenses/by/4.0/deed.de

Hinweis: Eingebundene Geodaten, Webdienste, Satellitendaten, OpenStreetMap-Daten oder Softwarebestandteile können eigenen Nutzungsbedingungen und Lizenzen unterliegen. Die CC-BY-4.0-Lizenz bezieht sich auf die selbst erstellten Texte, Abbildungen, Unterrichtsmaterialien und Strukturierungen dieses Pakets, soweit dort nichts anderes vermerkt ist.