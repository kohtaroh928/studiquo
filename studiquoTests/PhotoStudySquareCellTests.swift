import SwiftUI
import UIKit
import XCTest
@testable import studiquo

/// 写真資料の一覧で、写真の縦横比に関係なくサムネイルの枠が同じ正方形になることの確認。
@MainActor
final class PhotoStudySquareCellTests: XCTestCase {
    private func image(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func size(of image: UIImage?, cellWidth: CGFloat) -> CGSize {
        let host = UIHostingController(rootView: PhotoStudySquareCell(image: image))
        return host.sizeThatFits(in: CGSize(width: cellWidth, height: 1000))
    }

    func testCellIsSquareForAnyPhotoAspectRatio() {
        let cellWidth: CGFloat = 120
        let images: [UIImage?] = [
            nil,
            image(width: 400, height: 400),
            image(width: 1200, height: 300),   // 横長のパノラマ
            image(width: 300, height: 1200),   // 縦長
            image(width: 1170, height: 2532),  // スクリーンショット
        ]
        for image in images {
            let result = size(of: image, cellWidth: cellWidth)
            XCTAssertEqual(result.width, cellWidth, accuracy: 0.5)
            XCTAssertEqual(result.height, cellWidth, accuracy: 0.5)
        }
    }
}
