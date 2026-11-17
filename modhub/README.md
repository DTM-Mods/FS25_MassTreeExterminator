# ModHub upload: Mass Tree Exterminator

What to enter in the GIANTS ModHub upload form for this mod. Each text box below has a copy button on GitHub.

<img src="icon_512.png" alt="Mod icon" width="160">

**Mod Icon (512x512):** [`icon_512.png`](icon_512.png)

| Field | Value |
|-------|-------|
| Title English | Mass Tree Exterminator |
| Title German | Mass Tree Exterminator |
| Title French | Mass Tree Exterminator |
| Version | `1` `0` `0` `1` |
| Author | DTM Mods, Fennell |
| Manufacturer | Lizard |
| Category 1 | Gameplay |
| Category 2 | Not Set |
| Category 3 | Not Set |

## Title English
```text
Mass Tree Exterminator
```

## Title German
```text
Mass Tree Exterminator
```

## Title French
```text
Mass Tree Exterminator
```

## Description English
```text
Category: Landscaping > Mass Tree Exterminator (construction menu)
Price: $0 (you only pay for the trees and bushes you bulldoze)
Monthly upkeep: none

Bulldoze every tree and bush in an area at once, instead of clicking each tree with the bulldozer.

Open the construction menu (Shift + P by default), Landscaping > Mass Tree Exterminator. Left click one corner of the area and then the opposite corner: the area is drawn on the ground, the trees that will go get a red marker, and the cursor shows how many trees and how many m² of bushes there are and what it costs. Left click again and confirm to bulldoze them all. Right click takes back the last corner, Esc clears the area.

Every tree costs what the game's bulldozer (demolition mode) charges for it, and goes stump and all; bushes cost the construction menu's landscaping rate per m². Only trees and bushes on land of your own farm are removed; trees that have already been felled, and trees on other land, stay. Works in multiplayer (the server does the work and charges your farm).

Needs game version 1.25.1.0 or later (the bulldozer's tree fee).

Console: mteBushes switches removing bushes on or off, mteInfo writes the bulldozer's tree fee details to the log, mteTrace logs what the game's bulldozer does when you remove one tree by hand, mteDebug toggles debug logging.
```

## Description German
```text
Kategorie: Landschaftsbau > Mass Tree Exterminator (Baumenü)
Preis: 0 € (du zahlst nur für die Bäume und Büsche, die du abreißt)
Monatliche Unterhaltskosten: keine

Alle Bäume und Büsche einer Fläche auf einmal abreißen, statt jeden Baum einzeln mit dem Bulldozer anzuklicken.

Das Baumenü öffnen (Standard: Umschalt + P), Landschaftsbau > Mass Tree Exterminator. Eine Ecke der Fläche und dann die gegenüberliegende Ecke anklicken: Die Fläche wird am Boden angezeigt, die Bäume, die verschwinden, bekommen eine rote Markierung, und der Cursor zeigt, wie viele Bäume und wie viele m² Büsche es sind und was es kostet. Ein weiterer Linksklick mit Bestätigung reißt alles ab. Rechtsklick nimmt die letzte Ecke zurück, Esc löscht die Fläche.

Jeder Baum kostet so viel, wie der Bulldozer des Spiels (Abrissmodus) dafür verlangt, und verschwindet samt Stumpf; Büsche kosten den Landschaftsbau-Preis des Baumenüs pro m². Entfernt werden nur Bäume und Büsche auf Land des eigenen Hofs; bereits gefällte Bäume und Bäume auf fremdem Land bleiben stehen. Funktioniert im Multiplayer (der Server erledigt die Arbeit und belastet deinen Hof).

Benötigt Spielversion 1.25.1.0 oder neuer (die Baumgebühr des Bulldozers).

Konsole: mteBushes schaltet das Entfernen von Büschen ein oder aus, mteInfo schreibt die Details zur Baumgebühr des Bulldozers ins Log, mteTrace protokolliert, was der Bulldozer des Spiels tut, wenn du einen Baum von Hand entfernst, mteDebug schaltet Debug-Ausgaben um.
```

## Description French
```text
Catégorie : Aménagement paysager > Mass Tree Exterminator (menu de construction)
Prix : 0 € (vous ne payez que les arbres et buissons que vous rasez)
Entretien mensuel : aucun

Rasez d'un coup tous les arbres et buissons d'une zone, au lieu de cliquer chaque arbre avec le bulldozer.

Ouvrez le menu de construction (Maj + P par défaut), Aménagement paysager > Mass Tree Exterminator. Clic gauche sur un coin de la zone, puis sur le coin opposé : la zone est tracée au sol, les arbres qui vont disparaître reçoivent un marqueur rouge, et le curseur indique combien d'arbres et combien de m² de buissons il y a et ce que cela coûte. Cliquez encore une fois et confirmez pour tout raser. Le clic droit annule le dernier coin, Échap efface la zone.

Chaque arbre coûte ce que le bulldozer du jeu (mode démolition) demande pour lui, et disparaît avec sa souche ; les buissons coûtent le tarif d'aménagement paysager du menu de construction par m². Seuls les arbres et buissons sur les terres de votre ferme sont retirés ; les arbres déjà abattus et les arbres sur d'autres terres restent. Fonctionne en multijoueur (le serveur fait le travail et facture votre ferme).

Nécessite la version 1.25.1.0 du jeu ou plus récente (le tarif du bulldozer pour les arbres).

Console : mteBushes active ou désactive le retrait des buissons, mteInfo écrit dans le log les détails du tarif du bulldozer pour les arbres, mteTrace enregistre ce que fait le bulldozer du jeu quand vous retirez un arbre à la main, mteDebug active ou désactive le log de débogage.
```

## Before uploading

- The mod has no French: the in-game texts exist in English and German only, and modDesc.xml has only English and
  German descriptions. The French text here does not add translations to the mod.
- It ships console commands for checking the bulldozer's fee (`mteInfo`, `mteTrace`) and `mteDebug`. Your decision
  whether they stay in a ModHub build.
- Tested in single player; multiplayer (dedicated server) not confirmed yet.
- Screenshots for the upload: [`modhub/screenshots/`](screenshots) (1600x900, unedited in-game shots, `1.jpg` first).
