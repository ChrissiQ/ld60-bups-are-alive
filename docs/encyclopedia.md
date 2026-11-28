# The encyclopedia

What an entry says, and when it must change. Where the encyclopedia lives and how its links work is in [interface.md](interface.md#the-encyclopedia-and-tooltips).

The encyclopedia is kept true, complete and to concepts. An entry explains a term in up to two parts, kept apart as the Civilopedia keeps them:

- `<id>_about`: what it is in real life.
- `<id>_game`: how it works in the game (values, ranges, costs, and where the game departs from real life: a rate raised, a trait standing for many genes, a number that is a game choice).

An entry never says what to click or press, and never what a control does: that is the tutorial's (`[tutorial]`, the steps in `Main._start_tutorial`) and the tooltips', which are names and icons only.

- Every change that alters what an entry says (a constant, a cost, a rate, how a gene or mechanism works, a name, a range) updates the entry in the same change. Check the game part against the code, not from memory.
- A new gene, flag, mechanic, thing in the dish or term the player meets gets an entry (`scripts/encyclopedia.gd`, `[encyclopedia]` in `text/strings.cfg`).
- A changed or new interface part updates or adds a tutorial step.
- Anything about real biology is looked up and checked against sources before it is written ([sources.md](sources.md)): no misconception may stand in an educational text.

`tests/encyclopedia_test.gd` checks the links, that every gene has an entry and that no entry tells the player what to click. It cannot check the facts.
