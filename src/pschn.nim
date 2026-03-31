import std/[os, strutils, httpclient, base64, json, sequtils]
import dotenv, cligen

const Version = staticRead("../pschn.nimble").splitLines().filterIt(
    it.startsWith("version")).mapIt(it.split("=")[1].strip().strip(
    chars = {'"'}))[0]

const ApiBase = "https://panel.sendcloud.sc/api/v2"

proc loadEnv() =
  if fileExists(".env"):
    load()

proc getAuth(): string =
  loadEnv()
  let pub = getEnv("PSCHN_PUBLIC")
  let sec = getEnv("PSCHN_SECRET")
  if pub == "" or sec == "":
    quit "Error: PSCHN_PUBLIC and PSCHN_SECRET must be set", 1
  encode(pub & ":" & sec)

proc apiGet(path: string): JsonNode =
  let client = newHttpClient()
  client.headers = newHttpHeaders({
    "Authorization": "Basic " & getAuth(),
    "Content-Type": "application/json"
  })
  let resp = client.get(ApiBase & path)
  if resp.code.int div 100 != 2:
    quit "API error " & $resp.code & ": " & resp.body, 1
  parseJson(resp.body)

proc apiPost(path: string, body: JsonNode): JsonNode =
  let client = newHttpClient()
  client.headers = newHttpHeaders({
    "Authorization": "Basic " & getAuth(),
    "Content-Type": "application/json"
  })
  let resp = client.post(ApiBase & path, $body)
  if resp.code.int div 100 != 2:
    quit "API error " & $resp.code & ": " & resp.body, 1
  parseJson(resp.body)

proc downloadPdf(url, filename: string) =
  let client = newHttpClient()
  client.headers = newHttpHeaders({
    "Authorization": "Basic " & getAuth()
  })
  let resp = client.get(url)
  if resp.code.int div 100 != 2:
    quit "Failed to download label: " & $resp.code, 1
  writeFile(filename, resp.body)

proc label(name: string, street: string, houseNumber: string,
    postalCode: string, city: string, weight: string,
    email = "", phone = "", company = "",
    shipmentId = 0, output = "label.pdf"): int =
  ## Buy a DHL domestic label for a German address
  var sid = shipmentId
  if sid == 0:
    # Auto-detect DHL Germany shipping method
    let methods = apiGet("/shipping_methods")
    for m in methods["shipping_methods"]:
      if m["carrier"].getStr == "dhl":
        var isDe = false
        for c in m["countries"]:
          if c["iso_2"].getStr == "DE":
            isDe = true
            break
        if isDe:
          sid = m["id"].getInt
          break
    if sid == 0:
      quit "No DHL Germany shipping method found. Specify --shipment-id manually.", 1

  var parcel = %*{
    "parcel": {
      "name": name,
      "address": street,
      "house_number": houseNumber,
      "city": city,
      "postal_code": postalCode,
      "country": "DE",
      "weight": weight,
      "shipment": {"id": sid},
      "request_label": true
    }
  }
  if email != "":
    parcel["parcel"]["email"] = %email
  if phone != "":
    parcel["parcel"]["telephone"] = %phone
  if company != "":
    parcel["parcel"]["company_name"] = %company

  let resp = apiPost("/parcels", parcel)
  let p = resp["parcel"]

  let tracking = p["tracking_number"].getStr
  echo "Tracking: " & tracking

  let labelUrls = p{"label", "normal_printer"}
  if labelUrls == nil or labelUrls.kind != JArray or labelUrls.len == 0:
    quit "Label created but no PDF URL returned", 1

  downloadPdf(labelUrls[0].getStr, output)
  echo "Label saved to " & output
  return 0

proc methods(): int =
  ## List available shipping methods for Germany
  let resp = apiGet("/shipping_methods")
  for m in resp["shipping_methods"]:
    var isDe = false
    for c in m["countries"]:
      if c["iso_2"].getStr == "DE":
        isDe = true
        break
    if isDe:
      echo $m["id"].getInt & "\t" & m["carrier"].getStr & "\t" & m["name"].getStr

  return 0

proc senders(): int =
  ## List sender addresses
  let resp = apiGet("/sender_addresses")
  for s in resp["sender_addresses"]:
    echo $s["id"].getInt & "\t" & s["company_name"].getStr & " " &
        s["street"].getStr & " " & s["house_number"].getStr & ", " &
        s["postal_code"].getStr & " " & s["city"].getStr
  return 0

proc version(): int =
  ## Show version
  echo "pschn " & Version
  return 0

when isMainModule:
  dispatchMulti(
    [label, help = {
      "name": "recipient name",
      "street": "street name",
      "house-number": "house number",
      "postal-code": "postal code",
      "city": "city",
      "weight": "weight in kg (e.g. 2.000)",
      "email": "recipient email",
      "phone": "recipient phone",
      "company": "recipient company",
      "shipment-id": "shipping method ID (auto-detect DHL if 0)",
      "output": "output PDF filename"
    }],
    [methods],
    [senders],
    [version]
  )
