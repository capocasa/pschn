import std/[httpclient, json, base64, os, strutils, sequtils]
import dotenv, cligen

const Version = staticRead("../pschn.nimble").splitLines().filterIt(
    it.startsWith("version")).mapIt(it.split("=")[1].strip().strip(
    chars = {'"'}))[0]

proc loadConfig() =
  if fileExists(".env"):
    load()

type Config = object
  apiKey, user, pass, billingNumber: string
  senderName, senderStreet, senderPostalCode, senderCity: string
  sandbox: bool

proc getConfig(): Config =
  loadConfig()
  result = Config(
    apiKey: getEnv("DHL_API_KEY"),
    user: getEnv("DHL_USER"),
    pass: getEnv("DHL_PASS"),
    billingNumber: getEnv("DHL_BILLING_NUMBER"),
    senderName: getEnv("SENDER_NAME"),
    senderStreet: getEnv("SENDER_STREET"),
    senderPostalCode: getEnv("SENDER_POSTAL_CODE"),
    senderCity: getEnv("SENDER_CITY"),
    sandbox: getEnv("DHL_SANDBOX", "true") == "true",
  )
  if result.apiKey == "":
    quit "DHL_API_KEY not set", 1
  if result.billingNumber == "":
    quit "DHL_BILLING_NUMBER not set", 1
  if result.senderName == "":
    quit "SENDER_NAME not set", 1

proc buy*(name: string, street: string, postalCode: string, city: string,
    weight: int = 2000, output: string = "label.pdf"): int =
  ## Buy a DHL domestic parcel label
  let cfg = getConfig()
  let baseUrl = if cfg.sandbox:
    "https://api-sandbox.dhl.com/parcel/de/shipping/v2"
  else:
    "https://api-eu.dhl.com/parcel/de/shipping/v2"

  let body = %*{
    "profile": "STANDARD_GRUPPENPROFIL",
    "shipments": [
      {
        "product": "V01PAK",
        "billingNumber": cfg.billingNumber,
        "shipper": {
          "name1": cfg.senderName,
          "addressStreet": cfg.senderStreet,
          "postalCode": cfg.senderPostalCode,
          "city": cfg.senderCity,
          "country": "DEU"
        },
        "consignee": {
          "name1": name,
          "addressStreet": street,
          "postalCode": postalCode,
          "city": city,
          "country": "DEU"
        },
        "details": {
          "weight": {
            "uom": "g",
            "value": weight
          }
        }
      }
    ]
  }

  let client = newHttpClient()
  let creds = encode(cfg.user & ":" & cfg.pass)
  client.headers = newHttpHeaders({
    "dhl-api-key": cfg.apiKey,
    "Authorization": "Basic " & creds,
    "Content-Type": "application/json",
    "Accept": "application/json"
  })

  let url = baseUrl & "/orders?includeDocs=include&docFormat=PDF"
  let resp = client.post(url, body = $body)

  if resp.code != Http200:
    let errBody = resp.body
    try:
      let errJson = parseJson(errBody)
      stderr.writeLine "API error: ", errJson.pretty
    except:
      stderr.writeLine "API error (HTTP ", resp.code, "): ", errBody
    return 1

  let respJson = parseJson(resp.body)
  let items = respJson["items"]
  if items.len == 0:
    stderr.writeLine "No items in response"
    return 1

  let item = items[0]
  let status = item["sstatus"]["statusCode"].getInt()
  if status != 200:
    stderr.writeLine "Shipment error: ", item["sstatus"]["title"].getStr()
    if item["sstatus"].hasKey("detail"):
      stderr.writeLine item["sstatus"]["detail"].getStr()
    return 1

  let trackingNumber = item["shipmentNo"].getStr()
  let labelB64 = item["label"]["b64"].getStr()
  let labelData = decode(labelB64)

  writeFile(output, labelData)
  echo "Label saved to: ", output
  echo "Tracking: ", trackingNumber
  return 0

proc version*(): int =
  ## Show version
  echo "pschn " & Version
  return 0

when isMainModule:
  dispatchMulti(
    [buy, help = {
      "name": "recipient name",
      "street": "recipient street address",
      "postalCode": "recipient postal code",
      "city": "recipient city",
      "weight": "parcel weight in grams (default 2000)",
      "output": "output PDF file path (default label.pdf)",
    }],
    [version],
  )
