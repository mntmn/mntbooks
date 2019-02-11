#!/bin/bash
#
# pdfocr: A script to add selectable OCR text to scanned/image based PDFs 
# Copyright 2019 MNT Research GmbH (mntre.com)
# License: GPLv3+
#
# Usage: pdfocr <input.pdf> <output.pdf>

mkdir -p /tmp/pdfocr
rm /tmp/pdfocr/*

# split input document into .pnm pages
# -scene means start with number 1 for output pattern
convert -density 300 "$1" -depth 8 -strip -background white -alpha off -scene 1 "/tmp/pdfocr/scan%04d.pnm"

# process input pages for easier OCR-ing
unpaper -l single -w 0.8 "/tmp/pdfocr/scan%04d.pnm" "/tmp/pdfocr/unpaper%04d.pnm"

# OCR all the pages
i=0
for f in /tmp/pdfocr/unpaper*.pnm; do
  tesseract -l deu+eng "$f" "/tmp/pdfocr/ocr-$i" -psm 1 pdf
  i=$((i+1))
done

# unite all pages to create the output document
pdfunite /tmp/pdfocr/ocr-*.pdf $2

# comment this out for debugging/inspection
rm /tmp/pdfocr/*

