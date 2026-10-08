# AutoRankUp

A World of Warcraft: Forever addon (interface 16001) that swaps the old rank on your action bars for the new one when you train a higher spell rank.

## Install

Clone or download this repository into your WoW Forever client's `Interface\AddOns` folder so that the path ends in `Interface\AddOns\AutoRankUp\AutoRankUp.toc`, then `/reload`.

## Behaviour

- When a higher rank is learned, every action slot holding the previous highest rank is replaced with the new one.
- Slots holding an older rank you placed on purpose are left alone.
- Action bars can't be changed in combat, so a rank learned mid-fight is swapped when combat ends.
- Macros and pet abilities are not touched.

## Commands

- `/aru all` — replace every lower rank on your bars with the highest known rank
- `/aru debug` — print spell IDs when a new rank is detected
