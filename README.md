# mntbooks

mntbooks is a bookkeeping system developed for internal use at MNT Research GmbH.
The code is currently in garbage/sketch state. Most of it is written in Ruby using the Sinatra library for web requests. The database is sqlite3.
invoiserv.js is the legacy node.js-based invoicing system that is supposed to be ported into mntbooks' Ruby code.

## License

mntbooks is licensed under GPLv3+.

## Features

- Fetch and normalize transactions from FinTS (HBCI) bank accounts and Paypal accounts
- Workflow: unbooked transactions + unfiled documents -> booked transactions with attached receipts
- Autocomplete account names and receipts in unbooked transactions
- Auto-discovers PDFs that appear in a "Document Store" folder (for example from a document scanner), generates thumbnails
- PDF text extraction
- On-demand PDF rotation
- Ledger (plaintext accounting) export
- pdfocr.sh script helps with automated OCRing of incoming scanned receipts

# Dependencies

## APT

`apt install ghostscript imagemagick poppler-utils pdftk`

## Gems

`gem install sinatra sqlite3 paypal_nvp ruby_fints`

