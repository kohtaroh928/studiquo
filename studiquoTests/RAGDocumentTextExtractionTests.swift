import XCTest
import UIKit
@testable import studiquo
@MainActor
final class RAGDocumentTextExtractionTests: XCTestCase {
 typealias Extraction = RAGDocumentTextExtractionService
 func testNonemptyNativeGetsMissingImageTextWithoutReplacementOrDuplicates() {
  let native="元の本文はそのままです。\n図の説明"
  let r=Extraction.merge(nativeText:native,recognition:.init(lines:[.init(text:"元の本文はそのままです。",confidence:1),.init(text:"画像内にある新しい凡例",confidence:1),.init(text:"画像内にある新しい凡例",confidence:1)],failed:false))
  XCTAssertEqual(r.text,native+"\n画像内にある新しい凡例");XCTAssertEqual(r.supplementedLines,1);XCTAssertFalse(r.needsReview)
 }
 func testScannedTextLowConfidenceFailureAndEmptyRecognition() {
  let r=Extraction.merge(nativeText:"",recognition:.init(lines:[.init(text:"日本語のスキャン本文",confidence:1),.init(text:"不確かな認識結果",confidence:0.5),.init(text:"壊れた信頼度",confidence:.nan)],failed:false))
  XCTAssertEqual(r.text,"日本語のスキャン本文\n不確かな認識結果");XCTAssertEqual(r.rejectedLines,1);XCTAssertTrue(r.needsReview)
  XCTAssertTrue(Extraction.merge(nativeText:"本文",recognition:.init(lines:[],failed:true)).needsReview)
  XCTAssertTrue(Extraction.merge(nativeText:"",recognition:.init(lines:[],failed:false)).needsReview)
 }
 func testMathSymbolsStayIntactAndOCRDoesNotInventEquations() {
  let native="E = mc²\nα₁ + β₂ = γ"
  for formula in ["E = mc2","a / b = c","x−y","x-y","a<b","x² = y"] {
   let r=Extraction.merge(nativeText:native,recognition:.init(lines:[.init(text:formula,confidence:1)],failed:false))
   XCTAssertEqual(r.text,native);XCTAssertTrue(r.needsReview)
   XCTAssertEqual(Extraction.merge(nativeText:"",recognition:.init(lines:[.init(text:formula,confidence:1)],failed:false)).text,"")
  }
 }
 func testNearDuplicateMisreadsAndStableHashes() throws {
  let native="教材の本文に正しい説明が記載されています。"
  let recognition=Extraction.Recognition(lines:[.init(text:"教材の本文に正しぃ説明が記載されています。",confidence:1)],failed:false)
  let r=Extraction.merge(nativeText:native,recognition:recognition)
  XCTAssertEqual(r.text,native);XCTAssertTrue(r.needsReview)
  let pages=[RAGIndexingService.PageText(pageNumber:1,text:r.text)]
  XCTAssertEqual(try RAGIndexingService.sourceHash(pages),try RAGIndexingService.sourceHash([.init(pageNumber:1,text:Extraction.merge(nativeText:native,recognition:recognition).text)]))
 }
 func testLowConfidenceSupplementCannotReplaceNonemptyNative() {
  let r=Extraction.merge(nativeText:"元の文字層",recognition:.init(lines:[.init(text:"別の画像内の説明文",confidence:0.8)],failed:false))
  XCTAssertEqual(r.text,"元の文字層");XCTAssertEqual(r.rejectedLines,1);XCTAssertTrue(r.needsReview)
  let heading=Extraction.merge(nativeText:"",recognition:.init(lines:[.init(text:"Evaporation",confidence:1)],failed:false))
  XCTAssertEqual(heading.text,"Evaporation");XCTAssertFalse(heading.needsReview)
  let fragments=Extraction.merge(nativeText:"元の文字層",recognition:.init(lines:[.init(text:"(2.3.1)",confidence:1),.init(text:"Rd Tv p",confidence:1),.init(text:"2019 12 UTC JRA-55 NCEP JAPAN",confidence:1)],failed:false))
  XCTAssertEqual(fragments.text,"元の文字層");XCTAssertTrue(fragments.needsReview)
  let prose=Extraction.merge(nativeText:"元の文字層",recognition:.init(lines:[.init(text:"Surface pressure increases downward.",confidence:1)],failed:false))
  XCTAssertTrue(prose.text.contains("Surface pressure increases downward."));XCTAssertEqual(prose.supplementedLines,1)
 }
 private func imageData() -> Data {
  UIGraphicsImageRenderer(size:CGSize(width:100,height:100)).image { c in UIColor.white.setFill();c.fill(CGRect(x:0,y:0,width:100,height:100)) }.pngData()!
 }
 func testDamagedImageRetainsNativeAndRequiresReview() async {
  XCTAssertNotNil(Extraction.image(from:imageData()))
  let r=await Extraction.extract(nativeText:"保持する本文",imageData:Data([0]));XCTAssertEqual(r.text,"保持する本文");XCTAssertTrue(r.needsReview)
 }
 func testIndexChecksConsentAndLockAfterOCRBeforeUpload() async throws {
  let old=AIDataDisclosure.defaults
  AIDataDisclosure.defaults=UserDefaults(suiteName:"RAG-OCR-\(UUID().uuidString)")!;AIDataDisclosure.acknowledge(ageBand: .adult)
  let hadConsent=RAGConsent.isGranted
  defer { AIDataDisclosure.defaults=old;if hadConsent { RAGConsent.grant() } else { RAGConsent.revoke() } }
  for revoke in [true,false] {
   RAGConsent.grant();let notebook=Notebook(title:"Generated OCR test");let page=NotePage(order:0,backgroundImageData:imageData());page.recognizedText="文字層の本文";notebook.addPage(page)
   var uploads=0
   let service=RAGIndexingService(recognizer:{_ in
    if revoke { RAGConsent.revoke() } else { notebook.isLocked=true }
    return .init(lines:[],failed:false)
   },accountPartition:{"synthetic"},transport:{request in
    if request.httpMethod != "GET" { uploads += 1 }
    return (Data("{\"enabled\":true}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
   })
   do { try await service.index(notebook);XCTFail("Must not upload") } catch { XCTAssertEqual(uploads,0) }
  }
 }
 func testHundredScannedPagesKeepBoundariesBatchesAndReviewSummary() async throws {
  let old=AIDataDisclosure.defaults;AIDataDisclosure.defaults=UserDefaults(suiteName:"RAG-OCR-100-\(UUID().uuidString)")!;AIDataDisclosure.acknowledge(ageBand: .adult)
  let had=RAGConsent.isGranted;RAGConsent.grant()
  defer { AIDataDisclosure.defaults=old;if had { RAGConsent.grant() } else { RAGConsent.revoke() } }
  let notebook=Notebook(title:"Generated 100-page scan");let image=imageData()
  for i in 0..<100 { notebook.addPage(NotePage(order:i,backgroundImageData:image)) }
  var recognized=0;var batches:[[String:Any]]=[]
  let service=RAGIndexingService(recognizer:{_ in
   recognized += 1
   return .init(lines:[.init(text:"Synthetic OCR page \(recognized)",confidence:0.8)],failed:false)
  },accountPartition:{"synthetic"},transport:{request in
   if request.httpMethod != "GET" { batches.append(try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]) }
   return (Data("{\"enabled\":true}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
  })
  let result=try await service.index(notebook);XCTAssertEqual(recognized,100);XCTAssertEqual(batches.count,20)
  XCTAssertEqual(result.reviewPageNumbers,Array(1...100));XCTAssertEqual(result.supplementedPages,100)
  let pages=batches.flatMap{$0["pages"] as! [[String:Any]]}
  for (i,p) in pages.enumerated() { XCTAssertEqual(p["pageNumber"] as? Int,i+1);XCTAssertEqual(p["text"] as? String,"Synthetic OCR page \(i+1)") }
 }
 func testAccountAndEncryptionChangesAfterOCRBlockUpload() async throws {
  let old=AIDataDisclosure.defaults;AIDataDisclosure.defaults=UserDefaults(suiteName:"RAG-OCR-identity-\(UUID().uuidString)")!;AIDataDisclosure.acknowledge(ageBand: .adult)
  let had=RAGConsent.isGranted;RAGConsent.grant()
  defer { AIDataDisclosure.defaults=old;if had { RAGConsent.grant() } else { RAGConsent.revoke() } }
  for changeAccount in [true,false] {
   let notebook=Notebook(title:"Generated OCR test");notebook.addPage(NotePage(order:0,backgroundImageData:imageData()))
   var account:String?="synthetic-a";var uploads=0
   let service=RAGIndexingService(recognizer:{_ in
    if changeAccount { account="synthetic-b" } else { notebook.encryptedContent=Data([0]) }
    return .init(lines:[],failed:false)
   },accountPartition:{account},accountPartition:{"synthetic"},transport:{request in
    if request.httpMethod != "GET" { uploads += 1 }
    return (Data("{\"enabled\":true}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
   })
   do { try await service.index(notebook);XCTFail("Must block upload") } catch { XCTAssertEqual(uploads,0) }
  }
 }
 func testCancellationDuringOCRBlocksUpload() async throws {
  let old=AIDataDisclosure.defaults;AIDataDisclosure.defaults=UserDefaults(suiteName:"RAG-OCR-cancel-\(UUID().uuidString)")!;AIDataDisclosure.acknowledge(ageBand: .adult)
  let had=RAGConsent.isGranted;RAGConsent.grant()
  defer { AIDataDisclosure.defaults=old;if had { RAGConsent.grant() } else { RAGConsent.revoke() } }
  let notebook=Notebook(title:"Generated OCR test");notebook.addPage(NotePage(order:0,backgroundImageData:imageData()));var uploads=0
  let task=Task { @MainActor in
   let service=RAGIndexingService(recognizer:{_ in
    withUnsafeCurrentTask { $0?.cancel() };return .init(lines:[],failed:false)
   },accountPartition:{"synthetic"},transport:{request in
    if request.httpMethod != "GET" { uploads += 1 }
    return (Data("{\"enabled\":true}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
   })
   try await service.index(notebook)
  }
  do { _ = try await task.value;XCTFail("Must cancel") } catch { XCTAssertTrue(error is CancellationError);XCTAssertEqual(uploads,0) }
 }
}
