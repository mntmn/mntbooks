function makeReceiptList(id) {
  var listEl = document.getElementById(id)
  var newEl = document.getElementById(id+"-new")
  var list = []
  if (listEl.value.length>0) {
    list = listEl.value.split(",")
  } 
  if (newEl.value.length>0 && newEl.value.indexOf(".pdf")>0) {
    list.push(newEl.value)
    listEl.value = list.join(",")
    newEl.value = ""
  }
  renderPreviewLinks(id)
}

function renderPreviewLinks(id) {
  var target = document.getElementById(id+"-previews")
  var src = document.getElementById(id)

  if (src.value.length>0) {
    var docs = src.value.split(",")
    var html = "<table>"
    for (var i=0; i<docs.length; i++) {
      html += "<tr><td><a target='_blank' href='pdf/"+docs[i]+"'>"+docs[i]+"</a></td>"
      html += "<td><a class='btn' onclick=\"deleteReceiptLink('"+id+"',"+i+")\">🗑</a></td></tr>"
    }
    html += "</table>"
  } else {
    html = ""
  }
  target.innerHTML = html
}

function deleteReceiptLink(id, receiptIdx) {
  console.log(id,receiptIdx)
  var src = document.getElementById(id)
  var docs = src.value.split(",")
  var list = []
  for (var i=0; i<docs.length; i++) {
    if (i!=receiptIdx) list.push(docs[i])
  }
  src.value = list.join(",")
  
  renderPreviewLinks(id)
}

var sourceFunc = function(term, suggest) {
  term = term.toLowerCase()
  var choices = ACCOUNTS
  var matches = []
  for (i=0; i<choices.length; i++) if (~choices[i].toLowerCase().indexOf(term)) matches.push(choices[i])
  suggest(matches)
}

var sourceFuncReceipt = function(term, suggest) {
  term = term.toLowerCase()
  var choices = DOCUMENTS
  var matches = []

  if (term.length>0)
    for (i=0; i<choices.length; i++) {
      if ((choices[i].docid && ~(choices[i].docid+"").toLowerCase().indexOf(term))
          || (choices[i].tags && ~(choices[i].tags+"").toLowerCase().indexOf(term))
          || (choices[i].date && ~(choices[i].date+"").toLowerCase().indexOf(term))
          || (choices[i].path && ~(choices[i].path+"").toLowerCase().indexOf(term))
          || (choices[i].sum && ~(choices[i].sum+"").indexOf(term))) {
        matches.push(choices[i])
      }
    }
  suggest(matches)
}

var renderFuncReceipt = function (item, search){
  search = search.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&')
  var re = new RegExp("(" + search.split(' ').join('|') + ")", "gi")
  // highlight the search expressions
  var date_hl = "", sum_hl = "", docid_hl = "", tags_hl = ""
  if (item.date) date_hl   = item.date.replace(re, "<b>$1</b>")
  if (item.sum) sum_hl     = (item.sum+"").replace(re, "<b>$1</b>")
  if (item.docid) docid_hl = (item.docid+"").replace(re, "<b>$1</b>")
  if (item.tags) tags_hl   = item.tags.replace(re, "<b>$1</b>")
  path_hl = item.path.replace(re, "<b>$1</b>")
  
  var display = "<span class='sm'>"+date_hl+"</span><span class='smr'>"+sum_hl+"</span><br><span class='sm'>"+docid_hl+"</span><br>"+path_hl+"<br>"+tags_hl
  return '<div class="autocomplete-suggestion" data-val="' + item.path + '">' + display + '</div>'
}

var els = document.getElementsByClassName("account")
for (i=0;i<els.length;i++) {
  new autoComplete({
    selector: "#"+els[i].id,
    minChars: 0,
    source: sourceFunc
  })
}
var els = document.getElementsByClassName("receipt")
for (i=0;i<els.length;i++) {
  new autoComplete({
    selector: "#"+els[i].id,
    minChars: 0,
    source: sourceFuncReceipt,
    renderItem: renderFuncReceipt
  })
}
