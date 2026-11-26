# Sources

The published work the simulation and the encyclopedia take facts from. Each entry is looked up once and kept here, so a fact can be checked again without searching for it.

## Citing

- An entry's key is its first author's surname and the year, with a letter after the year when one author has two entries in a year (`Basan2015`, `Basan2020`; `Smith2019a`, `Smith2019b`).
- Code comments and the comments in `text/strings.cfg` cite an entry as `@Key`: `[search: @Biselli2020]`, or in prose, "(@Schink2019; @Biselli2020)". Several facts from one entry cite the same key.
- Text the player reads (the encyclopedia) names a source the way a reader expects ("Biselli, Schink and Gerland 2020"), and the comment above its key in `text/strings.cfg` cites the entry by its key.
- A new fact from the literature gets an entry here in the same change, with the paper's DOI (or a stable link where it has none) and the facts taken from it. When the figure, table or page a number comes from was checked, the entry says so.
- `tests/sources_test.gd` fails on a cited key with no entry and on an entry nothing cites.

The provenance tags beside a figure say where it comes from: `[search]` from a source (cited by its key), `[derived]` worked out from the code's rules and constants, `[measured]` read from a run, `[choice]` a game decision, `[placeholder]` not yet set with care, `[memory]` recalled and not checked against a source (treat it as unverified).

Not every sourced fact in the code is cited this way yet: some still name their source in prose ("Berg & Brown 1972") or carry `[memory]`. Converting one means adding its entry here and citing the key.

## Entries

### Basan2015

Basan M, Hui S, Okano H, Zhang Z, Shen Y, Williamson JR, Hwa T. Overflow metabolism in *Escherichia coli* results from efficient proteome allocation. *Nature* 528(7580): 99–104 (2015). [doi:10.1038/nature15765](https://doi.org/10.1038/nature15765)

- Used for: acetate overflow rising linearly with the growth rate above a threshold (`Biology` overflow section).

### Basan2020

Basan M, et al. A universal trade-off between growth and lag in fluctuating environments. *Nature* 584(7821): 470–474 (2020). [doi:10.1038/s41586-020-2505-4](https://doi.org/10.1038/s41586-020-2505-4)

- Used for: growth on acetate alone against growth on glucose (`Biology.ACETATE_UPTAKE`, `Genome.KEY_FACTOR`).

### Biselli2020

Biselli E, Schink SJ, Gerland U. Slower growth of *Escherichia coli* leads to longer survival in carbon starvation due to a decrease in the maintenance rate. *Molecular Systems Biology* 16(6): e9478 (2020). [doi:10.15252/msb.20209478](https://doi.org/10.15252/msb.20209478)

- Used for: the death rate of starving cells and its growth with the growth rate before starvation, the maintenance of a starving cell, the share of a dead cell the living recover (`Biology.STARVE_MAINTENANCE`, `STARVE_DEATH_RATE`, `STARVE_DEATH_GROWTH_HOURS`, `DEATH_RELEASE`, `DEATH_PER_SECOND`; the encyclopedia's starvation entry).
- Checked (abstract): the death rate depends on the earlier conditions only through the growth rate, slower growth giving exponentially slower death, through a lower maintenance rate per cell volume; the recycling yield stays constant.

### Enjalbert2017

Enjalbert B, Millard P, Dinclaux M, Portais JC, Létisse F. Acetate fluxes in *Escherichia coli* are determined by the thermodynamic control of the Pta-AckA pathway. *Scientific Reports* 7: 42135 (2017). [doi:10.1038/srep42135](https://doi.org/10.1038/srep42135)

- Used for: acetate not slowing growth at the concentrations a dish reaches (`Biology` overflow section).

### Glover2022

Glover G, Voliotis M, Łapińska U, Invergo BM, Soanes D, O'Neill P, Moore K, Nikolic N, Petrov PG, Milner DS, Roy S, Heesom K, Richards TA, Tsaneva-Atanasova K, Pagliara S. Nutrient and salt depletion synergistically boosts glucose metabolism in individual *Escherichia coli* cells. *Communications Biology* 5: 385 (2022). [doi:10.1038/s42003-022-03336-6](https://doi.org/10.1038/s42003-022-03336-6)

- Used for: the prevailing view that glucose uptake increases with a cell's surface area, and the finding that increasing cell size does not accelerate glucose metabolism in single cells (`Cell.UPTAKE_PER_MASS`).
- Checked (abstract, introduction, results and discussion; the reference list and the proteomics and statistics at the end were not read): "Seminal experiments carried out in chemostats suggest that glucose uptake increases with cell surface area"; the changes in glucose accumulation "are not dictated by changes in cell size"; "changes in cell size alone cannot account for the measured glucose accumulation traits". The uptake measured is that of the fluorescent glucose analogue 2-NBDG, in *E. coli* BW25113.

### Marshall2022

Marshall DJ, Malerba M, Lines T, Sezmis AL, Hasan CM, Lenski RE, McDonald MJ. Long-term experimental evolution decouples size and production costs in *Escherichia coli*. *Proceedings of the National Academy of Sciences* 119(21): e2200713119 (2022). [doi:10.1073/pnas.2200713119](https://doi.org/10.1073/pnas.2200713119)

- Used for: a measured scaling of whole-cell metabolism with cell volume within one species, kept as the counterpoint to the uptake law (`Cell.UPTAKE_PER_MASS`).
- Checked (title block, abstract and the start of the results): clones from the long-term evolution experiment, average volume from 0.239 fL for the ancestors to 0.670 fL at 60,000 generations; "The estimated scaling exponent for the metabolic rate, B, is 0.38, which differs significantly from interspecies comparisons". It compares evolved genotypes, not one cell as it grows, and the exponent is the metabolic rate against volume.

### Millard2023

Millard P, Gosselin-Monplaisir T, Uttenweiler-Joseph S, Enjalbert B. Acetate is a beneficial nutrient for *E. coli* at low glycolytic flux. *The EMBO Journal* (2023). [doi:10.15252/embj.2022113079](https://doi.org/10.15252/embj.2022113079)

- Used for: acetate not slowing growth at the concentrations a dish reaches (`Biology` overflow section).

### Nahku2010

Nahku R, Valgepea K, Lahtvee PJ, Erm S, Abner K, Adamberg K, Vilu R. Specific growth rate dependent transcriptome profiling of *Escherichia coli* K12 MG1655 in accelerostat cultures. *Journal of Biotechnology* 145(1): 60–65 (2010). [doi:10.1016/j.jbiotec.2009.10.007](https://doi.org/10.1016/j.jbiotec.2009.10.007)

- Used for: the growth rate at which acetate overflow begins (`Biology.ACETATE_THRESHOLD`).
- Checked (abstract): acetic acid accumulates from a growth rate of 0.34 ± 0.01 per hour.

### Pinhal2019

Pinhal S, Ropers D, Geiselmann J, de Jong H. Acetate metabolism and the inhibition of bacterial growth by acetate. *Journal of Bacteriology* 201(13): e00147-19 (2019). [doi:10.1128/JB.00147-19](https://doi.org/10.1128/JB.00147-19)

- Used for: growth on acetate alone against growth on glucose, and the acetate concentrations that slow growth (`Biology.ACETATE_UPTAKE`, the overflow section; `Genome.KEY_FACTOR`).

### Schink2019

Schink SJ, Biselli E, Ammar C, Gerland U. Death rate of *E. coli* during starvation is set by maintenance cost and biomass recycling. *Cell Systems* 9(1): 64–73 (2019). [doi:10.1016/j.cels.2019.06.003](https://doi.org/10.1016/j.cels.2019.06.003)

- Used for: starvation death as a constant rate set by maintenance and by what the living recover from the dead (`Biology` starvation section; the encyclopedia's starvation entry).

### Valgepea2010

Valgepea K, et al. Systems biology approach reveals that overflow metabolism of acetate in *Escherichia coli* is triggered by carbon catabolite repression of acetyl-CoA synthetase. *BMC Systems Biology* 4: 166 (2010). [doi:10.1186/1752-0509-4-166](https://doi.org/10.1186/1752-0509-4-166)

- Used for: the growth rate at which overflow begins, the share of glucose carbon let go as acetate, the yield per glucose not falling (`Biology.ACETATE_THRESHOLD`, `ACETATE_SLOPE`).
- Checked (abstract): overflow begins with the repression of acetyl-CoA synthetase at a growth rate of about 0.27 per hour.
