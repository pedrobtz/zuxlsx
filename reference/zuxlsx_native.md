# Report the native libraries zuxlsx was built against

zuxlsx vendors the 'xlsxio' reader and links 'Expat' and 'miniz'
statically out of the `zuxml` and `zukomp` packages, through
`LinkingTo`. This reports what it actually got, which is the quickest
way to tell a stale build from a current one.

## Usage

``` r
zuxlsx_native()
```

## Value

A list with elements `xlsxio`, `expat` and `miniz`.

## Examples

``` r
zuxlsx_native()
#> $xlsxio
#> [1] "0.2.36"
#> 
#> $expat
#> [1] "expat_2.8.4"
#> 
#> $miniz
#> [1] "11.3.2"
#> 
```
