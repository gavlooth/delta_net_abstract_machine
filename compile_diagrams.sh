#!/bin/env zsh
pandoc DELTA_K_IMPLEMENTATION_GUIDE.md \
  -o DELTA_K_IMPLEMENTATION_GUIDE.pdf \
  --pdf-engine=xelatex \
  -V mainfont='DejaVu Sans' \
  -V sansfont='DejaVu Sans' \
  -V monofont='Noto Sans Mono' \
  -V geometry:margin=1in
