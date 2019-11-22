#!/usr/bin/python3

import logging
import datetime
import re
import hashlib
import pprint
import sqlite3
import os

# needs psd2 branch of python-fints!
from fints.client import FinTS3PinTanClient, FinTSClientMode, FinTSUnsupportedOperation, NeedTANResponse
from fints.hhd.flicker import terminal_flicker_unix
import getpass

acc_id = os.environ["BANK_ACC"]
pin = os.environ["BANK_PIN"]
bank_code = os.environ["BANK_CODE"]
fints_url = os.environ["BANK_FINTS_URL"]

#logging.basicConfig(level=logging.DEBUG)

def process_rows(rows, acc_id):
    db_filename = "bank-"+str(acc_id)+".db"
    db = sqlite3.connect(db_filename)

    for row in rows:
        print("input row: -------------------------\n")
        pprint.pprint(row.data)
        
        amount_cents = int(row.data.get("amount").amount*100)
        # reconstruct old date format
        dt = row.data.get("date")
        raw_date = str(dt).replace('-','')[2:]
        # reconstruct old details format
        details_parts = [' SVWZ+',
                         str(row.data.get("purpose")),
                         str(row.data.get("additional_purpose") or ''),
                         str(row.data.get("end_to_end_reference") or ''),
                         str(row.data.get("applicant_bin")),
                         str(row.data.get("applicant_iban")),
                         str(row.data.get("applicant_name") or ''),
                         str(row.data.get("deviate_applicant") or '')]
        details = ' '.join(details_parts)
        txn_id = "v2"+hashlib.md5((raw_date+str(amount_cents)+details).encode('utf-8')).hexdigest()
        # reconstruct old "source" entry
        source = ''.join([raw_date,
                          str(row.data.get("status")),
                          str(row.data.get("amount").amount*100).replace('.',','),
                          str(row.data.get("id"))])
        
        db_row = [
            txn_id,
            str(dt),
            amount_cents,
            details,
            str(dt), # was: entry_date
            '', # was: storno_flag
            row.data.get("status"), # was: funds_code
            row.data.get("currency"), # was: currency_letter
            row.data.get("id"), # was: swift_code
            row.data.get("reference"),
            row.data.get("bank_reference"),
            row.data.get("transaction_code"),
            '?', # was: separator
            source
        ]

        print("\ndb row: ----------------------------\n")
        pprint.pprint(db_row)
        print("====================================\n\n")

        db.execute("REPLACE INTO transactions (id, date, amount_cents, details, entry_date, storno_flag, funds_code, currency_letter, swift_code, reference, bank_reference, transaction_code, seperator, source) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", db_row)
        db.commit()
        
    db.close()
        

# PSD2 example code from https://github.com/raphaelm/python-fints/pull/95#issue-322518811
    
f = FinTS3PinTanClient(
    bank_code, acc_id, pin, fints_url,
    mode=FinTSClientMode.INTERACTIVE,
)
f.fetch_tan_mechanisms()

try:
    with f:
        m = f.get_tan_media()
    f.set_tan_medium(m[1][0])
except FinTSUnsupportedOperation:
    print("TAN Mediums not supported.")

with f:
    if f.init_tan_response:
        print(f.init_tan_response.challenge)
        if getattr(f.init_tan_response, 'challenge_hhduc', None):
            try:
                terminal_flicker_unix(f.init_tan_response.challenge_hhduc)
            except KeyboardInterrupt:
                pass
        tan = input('Please enter TAN:')
        f.send_tan(f.init_tan_response, tan)

    # Fetch first account
    account = f.get_sepa_accounts()[0]

    res = f.get_transactions(account, datetime.date.today() - datetime.timedelta(days=30), datetime.date.today())
    while isinstance(res, NeedTANResponse):
        print(res.challenge)

        if getattr(res, 'challenge_hhduc', None):
            try:
                terminal_flicker_unix(res.challenge_hhduc)
            except KeyboardInterrupt:
                pass

        tan = input('Please enter TAN:')
        res = f.send_tan(res, tan)

    process_rows(res, acc_id)

        
