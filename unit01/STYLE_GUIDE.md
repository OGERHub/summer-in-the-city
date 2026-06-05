# Verbindliche Stil- und Strukturvorgabe

Diese Vorgabe beschreibt den Arbeitsstil für die Quarto-Seiten des Geländeklimatologie-/fieldClim-Kurses. Sie ist absichtlich enger gefasst als eine allgemeine Quarto-Dokumentation. Ziel ist, neue Seiten so anzulegen, dass sie wie Teil derselben Kurswebsite wirken und nicht wie extern gerenderte Einzeldateien.

## 1. Inhaltliche Leitlinie

Der Kurs ist kein neuer Theorieblock zur Meteorologie. Die Studierenden haben die fachlichen Grundlagen zu Geländeklima, Mikroklima, Strahlung und Energiehaushalt bereits erarbeitet. Die Seiten übersetzen diese Theorie in Anwendung: aus Messstandorten werden Dateien, aus Dateien werden prüfbare Zeitreihen, aus Zeitreihen werden `fieldClim`-Objekte, und aus diesen Objekten entstehen methodisch begrenzte Aussagen.

Die Texte sollen diese Übersetzung erklären. Sie dürfen nicht zu Checklisten oder reinen Bedienanweisungen verarmen. Jede Seite braucht deshalb eine kurze fachliche Rahmung, einen nachvollziehbaren Arbeitsgang in R und eine Interpretation, die ausdrücklich sagt, was das Ergebnis leisten kann und was nicht.

## 2. Textstil

Der Grundstil ist sachlich, dicht und erklärend. Absätze sollen führen, nicht nur ankündigen. Listen sind erlaubt, wenn sie echte Vergleichbarkeit herstellen; sie ersetzen aber nicht die Erklärung. Die bevorzugte Form ist ein kurzer Fließtext, dann ein kleiner Codeblock, dann eine deutende Einordnung.

Nicht erwünscht sind Aufgabenwüsten, Methodenlexika, dekorative Motivationssprache oder stark verkürzte Schlagworttexte. Begriffe wie „Arbeitsprinzip“, „Interpretation“ oder „Kontrolle“ sind besser als didaktische Sprechweisen wie „Kniff“, „Hack“ oder „Trick“.

## 3. R- und Code-Stil

Der Code bleibt bewusst schlicht. Standard sind `read.csv()`, direkte Spaltenzugriffe mit `$`, `data.frame()`, `summary()`, `plot()`, `lines()`, `legend()` und `here::here()` für Projektpfade. `ggplot2`, Shiny, Widgets oder komplexe Helferfunktionen gehören nicht in den Basiskurs, sofern sie nicht ausdrücklich fachlich notwendig sind.

Pfade werden relativ gedacht. Kursdaten liegen unter `data/`, Abbildungen unter `images/` oder `images/figures/`, Bibliographie unter `assets/`. Wenn Paketdaten genutzt werden, darf ein Fallback über `system.file()` verwendet werden. Der Fallback muss im Text erklärt werden, damit klar bleibt, ob gerade mit Kursdaten oder Paketdaten gearbeitet wird.

## 4. Infografikstil

Die Infografiken verwenden einen ruhigen, hochwertigen Card-/Workflow-Stil. Charakteristisch sind helle Hintergründe, klare blaue Konturen, weiche Schatten, sparsame Icons, leicht isometrische Karten- oder Stationsmotive und eine gedämpfte naturwissenschaftliche Farbpalette. Die Grafiken sollen Beziehungen und Abläufe sichtbar machen, nicht den Fließtext ersetzen.

Längere Überschriften und Erklärungen stehen im `.qmd`, nicht in der Grafik. In der Grafik selbst stehen kurze, präzise Labels. Text muss großzügig gesetzt sein und darf nicht aus Boxen laufen. Die Figuren sollen als visuelle Anker funktionieren: Theorie → Messung → Datenstruktur → Methode → Interpretation.

## 5. Quarto-Seitenmuster

Normale Kursseiten liegen in `unit01/`. Jede Seite erhält einen knappen YAML-Header mit Titel, Banner, Bibliographie, Sprache und Kommentarstatus. Globale Dinge wie Theme, TOC, Code-Copy, CSS und Echo-Optionen bleiben in `_quarto.yml` und werden nicht seitenlokal wiederholt.

Eine Seite beginnt mit einer fachlichen Zielklärung, nicht mit einem Codeblock. Danach folgt ein kleiner Abschnitt, der den Arbeitsfall beschreibt. Codeblöcke werden durch Text vorbereitet und anschließend interpretiert. Am Ende steht ein Arbeitsauftrag oder eine Ergebnisprüfung, aber nicht als lange Liste, sondern als fokussierte Anwendung.

## 6. Figure-Integration

Abbildungen werden bevorzugt mit Markdown eingebunden, zum Beispiel:

```markdown
![Vom Messstandort zum `weather_station`-Objekt.](../images/figures/fig01_station_object.svg){fig-align="center" width="95%"}
```

Die Caption beschreibt knapp, was die Abbildung zeigt. Die eigentliche Erklärung steht im Absatz davor oder danach. Für Kursseiten in `unit01/` gilt der relative Pfad `../images/figures/...`.
