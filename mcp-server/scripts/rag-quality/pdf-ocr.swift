import Foundation
import AppKit
import PDFKit
import Vision
struct Page: Codable { let pageNumber:Int; let topic:String; let text:String; let scan:Bool; let fact:String }
struct Fixture:Codable {let pages:[Page]}
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let fixture=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:root.appendingPathComponent("fixture.json")))
class Sheet:NSView {
 var text="";var number=0
 override var isFlipped:Bool {true}
 override func draw(_ dirtyRect:NSRect){
  NSColor.white.setFill();bounds.fill()
  let font=NSFont(name:"HiraginoSans-W3",size:13) ?? NSFont.systemFont(ofSize:13)
  let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=5
  (text as NSString).draw(in:NSRect(x:44,y:42,width:524,height:704),withAttributes:[.font:font,.foregroundColor:NSColor.black,.paragraphStyle:paragraph])
  (String(number) as NSString).draw(at:NSPoint(x:290,y:765),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.gray])
 }
}
let document=PDFDocument()
for p in fixture.pages {
 let view=Sheet(frame:NSRect(x:0,y:0,width:612,height:792));view.text=p.text;view.number=p.pageNumber
 let data=view.dataWithPDF(inside:view.bounds)
 let pageDocument=PDFDocument(data:data)!
 let page=pageDocument.page(at:0)!
 if p.scan {
  let image=page.thumbnail(of:NSSize(width:1224,height:1584),for:.mediaBox)
  document.insert(PDFPage(image:image)!,at:document.pageCount)
 } else {document.insert(page,at:document.pageCount)}
}
let output=root.appendingPathComponent("japanese-quality-100-pages.pdf")
guard document.write(to:output) else {fatalError("pdf_write_failed")}
let loaded=PDFDocument(url:output)!
var records:[[String:Any]]=[]
for p in fixture.pages {
 let page=loaded.page(at:p.pageNumber-1)!
 let layer=page.string ?? ""
 var recognized=layer
 if p.scan {
  let image=page.thumbnail(of:NSSize(width:1224,height:1584),for:.mediaBox)
  var rect=NSRect(origin:.zero,size:image.size)
  let cg=image.cgImage(forProposedRect:&rect,context:nil,hints:nil)!
  let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.recognitionLanguages=["ja-JP","en-US"];request.usesLanguageCorrection=true
  let start=Date()
  try VNImageRequestHandler(cgImage:cg,options:[:]).perform([request])
  recognized=(request.results ?? []).compactMap{$0.topCandidates(1).first?.string}.joined(separator:"\n")
  records.append(["pageNumber":p.pageNumber,"text":recognized,"textLayerEmpty":layer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,"ocrMs":Int(Date().timeIntervalSince(start)*1000)])
  print("OCR page \(p.pageNumber) completed")
 } else {records.append(["pageNumber":p.pageNumber,"text":recognized,"textLayerEmpty":false])}
}
try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("extracted-pages.json"))
print("PDF pages \(loaded.pageCount), OCR pages \(records.filter{$0["ocrMs"] != nil}.count)")
