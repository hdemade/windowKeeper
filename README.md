# WindowKeeper

<img src="AppIcon.iconset/icon_128x128@2x.png" width="128" alt="Icône de WindowKeeper">

Petite app de barre de menus pour macOS (Apple Silicon, macOS 13 ou plus récent) qui mémorise la disposition des fenêtres (position, taille, écran, bureau) pour chaque configuration d'écrans et la remet en place quand on branche ou débranche des écrans. SIP reste activé : l'app n'injecte rien dans le Dock.

## Installation

```
bash build.sh install
```

L'app est compilée hors d'iCloud Drive (`~/Library/Caches/WindowKeeper-build`), installée dans `/Applications` puis lancée (si le compte n'est pas administrateur, macOS demande le mot de passe d'un administrateur ; `DEST=~/Applications bash build.sh install` installe ailleurs). Une ancienne copie dans `~/Applications` est supprimée. Au premier lancement, accordez-lui l'autorisation dans Réglages Système > Confidentialité et sécurité > Accessibilité.

## Image disque (DMG)

```
bash make-dmg.sh
```

Crée `WindowKeeper-<version>.dmg` dans le dossier de build. L'app n'est pas certifiée par Apple : sur un autre Mac, au premier lancement, il faut l'autoriser dans Réglages Système > Confidentialité et sécurité > « Ouvrir quand même ».

## Fonctionnement

- Chaque combinaison d'écrans (portable seul, portable + écrans du bureau, etc.) a sa propre disposition.
- La disposition est sauvegardée automatiquement (toutes les 30 secondes par défaut, de 10 secondes à 15 minutes dans les réglages), donc la dernière sauvegarde avant un débranchement est celle qui sera restaurée au retour sur cette configuration.
- En plus de ce dernier état automatique, on peut garder plusieurs sauvegardes nommées par configuration (« Nouvelle sauvegarde ») et les restaurer à la demande depuis la fenêtre ou le menu. Dans la fenêtre, chaque configuration se déplie pour les montrer, et un clic droit permet de renommer (directement dans la liste, Entrée pour valider, Échap pour annuler) ou de supprimer. Dans le détail, un double-clic sur le titre le renomme aussi.
- Les réglages (bouton « Réglages… » en bas de la colonne de gauche, ⌘, ou menu de la barre des menus) regroupent la sauvegarde et la restauration automatiques, leur intervalle, le lancement à l'ouverture de session et les mises à jour.
- Une fois par jour, l'app regarde la dernière version publiée sur GitHub (https://github.com/hdemade/windowKeeper/releases) et signale une version plus récente dans la fenêtre, le menu et les réglages, avec un lien vers l'image disque. Rien n'est installé automatiquement. La vérification peut être désactivée dans les réglages.
- Quand les écrans changent, ou au réveil, l'app attend quelques secondes que macOS se stabilise puis restaure la disposition de la configuration courante.
- Les données sont dans `~/Library/Application Support/WindowKeeper/layouts.json`, le journal dans `~/Library/Logs/WindowKeeper.log`.

## Diagnostic

```
/Applications/WindowKeeper.app/Contents/MacOS/WindowKeeper --diagnose
/Applications/WindowKeeper.app/Contents/MacOS/WindowKeeper --selftest
```

`--selftest` ouvre une petite fenêtre de test et vérifie quelle méthode de changement de bureau macOS accepte sur cette machine.

## Limites connues

- Le changement de bureau d'une fenêtre repose sur des fonctions non documentées de macOS. Une mise à jour de macOS peut les casser ; dans ce cas l'app continue de restaurer positions, tailles et écrans, et le rapport de restauration liste les fenêtres restées sur le mauvais bureau.
- L'app ne crée pas de bureaux : si un bureau enregistré n'existe plus, il faut le recréer dans Mission Control.
- Les fenêtres en plein écran sont ignorées. Les fenêtres fermées ne sont pas rouvertes.
- L'app est signée sans certificat : après chaque recompilation, il faut supprimer puis redonner l'autorisation Accessibilité.
- Le changement de bureau a été vérifié sur macOS 26.7 (méthode « bridged »). Les méthodes de repli pour les versions plus anciennes ne sont pas testées.
- Dans Mission Control, décochez « Réarranger automatiquement les Spaces en fonction de votre utilisation la plus récente » pour que l'ordre des bureaux reste stable.
