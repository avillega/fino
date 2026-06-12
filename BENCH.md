# Benchmark Results

Four AST/value-storage strategies compared using ReleseFast

## AST size (MB)

Bytes the parsed tree occupies in memory; the static footprint of the chosen node layout.
Node counts differ because some layouts fold structure that others store as explicit nodes.

moar_smaller   ███████                                    15.9 MB   1.00x *
post_tree      ████████████                               25.5 MB   1.60x
forest_pointer ████████████████████████████████████████   86.4 MB   5.42x
index_sea      █████████████████████████                  53.1 MB   3.33x

Layout per strategy:
moar_smaller   3,186,490 nodes, 1B tag + 4B node
post_tree      3,186,490 nodes, 8B/node
forest_pointer 2,475,457 nodes, 32B/node + child slices
index_sea      2,475,457 nodes, 895,387 extra, 20B/node

## Wall time (hyperfine, mean ms)

End-to-end clock time per run

moar_smaller   ████████████████████████                  68.4 ms ± 0.6   1.00x
post_tree      ████████████████████████                  68.2 ms ± 0.7   1.00x *
forest_pointer ████████████████████████████████████████ 112.5 ms ± 1.1   1.65x
index_sea      ███████████████████████████               76.7 ms ± 0.7   1.12x

## Instructions retired (billions)

Total CPU instructions executed

moar_smaller   ██████████████████████████████████        1.243 B   1.06x
post_tree      ████████████████████████████████          1.176 B   1.00x *
forest_pointer ████████████████████████████████████████  1.462 B   1.24x
index_sea      ███████████████████████████████████       1.296 B   1.10x

## Cycles elapsed (millions)

CPU clock cycles consumed, higher-than-instructions growth hints at cache misses / memory stalls.

moar_smaller   ████████████████████████                  235.7 M   1.00x *
post_tree      ████████████████████████                  239.1 M   1.01x
forest_pointer ████████████████████████████████████████  396.4 M   1.68x
index_sea      ███████████████████████████               267.7 M   1.14x

## Effective IPC (instructions ÷ cycles)

Instructions completed per CPU cycle

moar_smaller   ████████████████████████████████████████  5.27   1.00x *
post_tree      █████████████████████████████████████     4.92   1.07x
forest_pointer ████████████████████████████              3.69   1.43x
index_sea      █████████████████████████████████████     4.84   1.09x

## Peak memory footprint (MB)

Most memory the process touched at once

moar_smaller   █████                                      33.0 MB   1.00x *
post_tree      ████████                                   57.6 MB   1.75x
forest_pointer ████████████████████████████████████████  288.8 MB   8.75x
index_sea      ██████████                                 69.9 MB   2.12x

## Max resident set size (MB)

Peak physical RAM the OS kept resident for the process (includes runtime/allocator overhead).

moar_smaller   ███████                                    49.6 MB   1.00x *
post_tree      ██████████                                 73.1 MB   1.47x
forest_pointer ████████████████████████████████████████  293.7 MB   5.92x
index_sea      ████████████                               85.4 MB   1.72x

