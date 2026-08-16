#!/bin/env zsh
pandoc NEXT_STEPS_GUIDE.md \
  -o  NEXT_STEPS_GUIDE.pdf \
  --pdf-engine=xelatex \
  -V mainfont='DejaVu Sans' \
  -V sansfont='DejaVu Sans' \
  -V monofont='Noto Sans Mono' \
  -V geometry:margin=1in
