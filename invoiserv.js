const express = require('express')
const bodyParser = require('body-parser')
const basicAuth = require('express-basic-auth')
const resolve = require('path').resolve
const crypto = require('crypto')
const fs = require('fs')
const exec = require("child_process").exec
const nunjucks = require("nunjucks")
const expressNunjucks = require('express-nunjucks')
const csv = require("async-csv")
const zpad = require('zpad')

const csvFolder = './invoices-csv'
const htmlFolder = './invoices-html'
const pdfFolder = './invoices-pdf'
const key = process.env.INVOISERV_KEY

const EU = ["AT", "BE", "BG", "CY", "CZ", "DE", "DK", "EE", "EL", "ES", "FI", "FR", "HR", "HU", "IE", "IT", "LT", "LU", "LV", "MT", "NL", "PL", "PT", "RO", "SE", "SI", "SK", "UK"]

if (!key) {
  console.error("Please set INVOISERV_KEY env variable.")
  process.exit(1)
}

const year = new Date().getYear()+1900

var nextInvoiceNumber = 1

const app = express()
const isDev = app.get('env') === 'development'
app.set('views', __dirname + '/templates')
const njk = expressNunjucks(app, {
    watch: isDev,
    noCache: isDev
})
app.use(bodyParser.raw({type:"application/*"}))

// templating functions
var templEnv = new nunjucks.Environment(new nunjucks.FileSystemLoader('templates'))
function money_format(input) {
  return parseFloat(input).toFixed(2).replace(".",",")
}
templEnv.addFilter("money",money_format)

const taxRates = {
  "8400": 0.19
}

function getTaxRate(acc) {
  let r = taxRates[""+acc]
  if (!r) r = 0.0
  return r
}

async function csvToInvoiceRows(csvPath) {
  let rawCSV = ""+fs.readFileSync(csvPath)
  let rows = await csv.parse(rawCSV, {auto_parse:false, from:2})

  rows = rows.map(raw => {
    console.log(raw.length,raw)

    let inclVAT = true
    if (raw.length>16) {
      inclVAT = +raw[16]
    }
    
    return {
      date: Date.parse(raw[0]),
      amount: parseFloat(raw[1]),
      currency: raw[2],
      credit_account: parseInt(raw[3]),
      debit_account: raw[4],
      payment_method: raw[5],
      company: raw[6],
      name: raw[7],
      addr1: raw[8],
      addr2: raw[9],
      zip: raw[10],
      city: raw[11],
      state: raw[12],
      country_iso2: raw[13],
      order_number: raw[14],
      items: raw[15].split("$"),
      incl_vat: inclVAT,
      csv: rawCSV
    }
  })

  return rows
}

function getNextInvoiceNumber() {
  nextInvoiceNumber = parseInt(fs.readFileSync("./next-invoice-number.dat"))
  return nextInvoiceNumber
}

function getISODate(d) {
  return (new Date(d)).toISOString().substr(0,10)
}

function invoiceRowsToHTML(rows) {
  getNextInvoiceNumber()
  // sort by date
  rows.sort((a,b) => {return a.date-b.date}).map(function(invoice) {
    var iid = year+"-"+zpad(nextInvoiceNumber++, 4)
    var positions = []
    var total = 0
    var c = 1
    
    for (var i = 0; i < invoice.items.length; i++) {
      var pparts = invoice.items[i].split("|");
      var p = {}

      if (pparts.length==4) {
        p = {
          pos: c++,
          title:  pparts[0],
          amount: pparts[1],
          price:  pparts[2],
          desc:   pparts[3],
          sum:    parseFloat(pparts[1])*parseFloat(pparts[2])
        }
      } else {
        p = {
          pos: c++,
          title: invoice.items[i],
          amount: 1,
          price: invoice.amount,
          sum: invoice.amount,
          desc: ""
        }
      }
      positions.push(p);
      total += parseFloat(p.sum);
    }

    total = Math.round(total*100)/100

    if (total != invoice.amount) {
      console.error("Error: total doesn't add up for invoice "+iid+" "+total+" vs "+invoice.amount)
    }

    var tax = 0
    var taxrate = 0
    var inEU = false
    
    if (EU.indexOf(invoice.country_iso2) != -1) {
      inEU = true
      taxrate = getTaxRate(invoice.credit_account)
      if (invoice.incl_vat) {
        tax = total - (total / (1+taxrate))
      } else {
        tax = total*taxrate
        total = total+tax
      }
    }
    
    var outro = "";
    if (!inEU) {
      outro = "Steuerfreie Ausfuhrlieferungen nach § 4 Nr. 1a UStG in Verbindung mit § 6 UStG."
    }
    
    var isCancelled = false
    var address = [invoice.company,invoice.name,invoice.addr1,invoice.addr2,invoice.zip+" "+invoice.city,invoice.state+" "+invoice.country_iso2]

    var lname = invoice.company
    if (!lname) {
      var nameParts = invoice.name.split(" ")
      lname = nameParts[nameParts.length-1]
    }

    var terms = "Bitte begleichen Sie die Rechnung innerhalb von 7 Tagen ab Rechnungsdatum."

    if (invoice.payment_method.toLowerCase().match("paypal")) {
      var terms = "Die Rechnung wurde bereits per PayPal bezahlt."
    }

    if (invoice.payment_method.toLowerCase().match("cash")) {
      var terms = "Die Rechnung wurde bereits bar bezahlt."
    }

    var date = getISODate(invoice.date)

    var vars = {
      iid: iid,
      idate: date,
      ddate: date,
      address: address,
      hello: "",
      intro: "",
      outro: outro,
      positions: positions,
      total: total - tax,
      tax: tax,
      taxrate: taxrate*100+"%",
      grand_total: total,
      lname: lname,
      terms: terms,
      ordernum: invoice.order_number,
      csv: invoice.csv
    }

    renderInvoice(vars,inEU)
  })

  console.log("Next Invoice Number:", nextInvoiceNumber)
  fs.writeFileSync("./next-invoice-number.dat", ""+nextInvoiceNumber)
}

function renderInvoice(vars) {
  var html = templEnv.render("invoice.html", vars)
  var outpath = vars.lname+"-"+vars.ordernum+"-"+vars.iid
  outpath = outpath.replace(/[^a-zA-Z0-9\-_\.]/g,"")

  var htmlpath = htmlFolder+"/"+outpath+".html"
  var pdfpath = pdfFolder+"/"+outpath+".pdf"
  fs.writeFileSync(htmlpath, html)
  exec("wkhtmltopdf -s A4 -L 20 -T 20 -R 10 -B 10 "+htmlpath+" "+pdfpath)
}

// public route ---------------------------------------------------------------------

const idMatchRX = /^[a-zA-Z0-9\-]+$/g

app.get('/invoices/:id', (req, res) => {
  var id = req.params.id+""
  var given_hash = req.query.hmac
  
  if (given_hash && id.match(idMatchRX) && id.length>=8) {
    var files = fs.readdirSync(pdfFolder)
    files = files.filter(f => {
      return (f.match(id) && f.match(/\.pdf$/))
    })
    if (files.length) {
      var expected_hash = crypto.createHmac('sha256', key).update(id).digest('hex')
      if (given_hash == expected_hash) {
        var file = resolve(pdfFolder+'/'+files[0])
        res.sendFile(file)
      } else {
        res.sendStatus(404)
      } 
    } else {
      res.sendStatus(404)
    }
  } else {
    res.sendStatus(400)
  }
})

// private routes ------------------------------------------------------------------

app.use(basicAuth({
  users: { 'mntmn-invoices': 'extremgeheimestuffs' },
  challenge: true,
  realm: 'void'
}))

app.get('/invoices-admin/invoices', (req, res) => {
  var pdfs = fs.readdirSync(pdfFolder).filter(f => { return f.match(/\.pdf$/) })

  pdfs = pdfs.map(f => {
    var id = f.match(/([a-zA-Z0-9\-]+)/)[0]
    console.log("Requested Invoice:",id)

    return {
      id: id,
      path: f,
      url: "/invoices/"+id+"?hmac="+crypto.createHmac('sha256', key).update(id).digest('hex')
    }
  })

  res.render('invoice_list', {
    invoices: pdfs
  })
})

app.get('/invoices-admin/invoices/new', (req, res) => {
  // display invoice form
  res.render('invoice_form', {
    iid: getNextInvoiceNumber(),
    idate: getISODate(new Date())
  })
})

app.post('/invoices-admin/invoices', async (req, res) => {
  var body = ""+req.body
  console.log("POST:",body)
  var csvPath = csvFolder+'/'+getISODate(new Date())+'-'+getNextInvoiceNumber()+'.csv'
  fs.writeFileSync(csvPath, body)

  var rows = await csvToInvoiceRows(csvPath)
  invoiceRowsToHTML(rows)
  res.redirect('/invoices')
})

app.listen(3100)
console.log("MNT invoiserv listening on port 3100")
