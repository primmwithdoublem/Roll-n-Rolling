# Roll'n'Rolling

A lightweight World of Warcraft (3.3.5a) addon built for **Grimfall Classless** that gives you an organized, resizable overview of all your learned active spells and talents—with recent-roll tracking and quick unlearning directly through the native Classless UI.

## Features

- **Unified Learned Overview:** Displays all learned talents (with current/max ranks) and active spells in a clean, scrollable grid.
- **Recently Rolled Highlighting:** Tracks newly rolled spells and talent rank-ups during your play session, highlighting them with a cyan border and sorting them to the front.
- **Native Unlearn Mode (`Unlearn: ON`):** Toggle Unlearn Mode to click any spell or talent icon in the overview and automatically trigger the native Classless right-click **Unlearn** action—even if the entry is off-screen in a scrolled list.
- **Class Source Identification & Labels (`Labels: ON`):** Displays the originating class in tooltips and optional icon sub-labels.
- **Quick Classless Header Button:** Adds a spellbook toggle icon directly to the top-right header of the Classless window.
- **Resizable & Movable Window:** Drag the title bar to reposition or drag the bottom-right corner handle to resize the window; the icon grid dynamically reflows to fit.

## Slash Commands

- `/rnr` — Toggle the **Roll'n'Rolling** overview window.
- `/learned` — Alias to toggle the overview window.

## Installation

1. Download or clone this repository.
2. Copy the `Roll'n'Rolling` folder into your World of Warcraft `Interface\AddOns\` directory:
   ```text
   World of Warcraft\Interface\AddOns\Roll'n'Rolling\
   ├── Roll'n'Rolling.lua
   └── Roll'n'Rolling.toc
