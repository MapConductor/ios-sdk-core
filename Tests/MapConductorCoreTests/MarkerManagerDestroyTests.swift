import XCTest

@testable import MapConductorCore

/// 破棄後の `MarkerManager` アクセスの扱い。
///
/// プロバイダ切り替えのように destroy → 生成が続けて起きる場面では、進行中の
/// 非同期処理（Combine の配送、await から戻ってきたレンダラ往復、コレクタの
/// デバウンス窓に溜まっていた更新）が destroy 直後に到着しうる。これは正常な競合なので
/// 例外は投げず、ログを出して無視する。
///
/// ただし**書き込みは行わない**。マネージャはマップ 1 つにつき 1 個で、プロバイダを
/// 切り替えると新しいマップが自前のマネージャを作る（再利用しない）。破棄済みへ書き戻すと
/// 誰も参照しないオブジェクトが再び状態を持つだけになる。
/// android-sdk / react-sdk と同じ意味論であることをここで固定する。
final class MarkerManagerDestroyTests: XCTestCase {

    private func makeEntity(id: String) -> MarkerEntity<Int> {
        MarkerEntity(
            marker: 1,
            state: MarkerState(position: GeoPoint(latitude: 35.0, longitude: 139.0), id: id),
            isRendered: true
        )
    }

    /// 破棄後の registerEntity は書き込まない。
    func testRegisterEntityIsIgnoredAfterDestroy() {
        let manager = MarkerManager<Int>()
        manager.destroy()

        manager.registerEntity(makeEntity(id: "a"))

        XCTAssertNil(manager.getEntity("a"), "破棄後に登録したエンティティが残ってはいけない")
        XCTAssertTrue(manager.allEntities().isEmpty)
    }

    /// 破棄後の updateEntity も書き込まない。
    func testUpdateEntityIsIgnoredAfterDestroy() {
        let manager = MarkerManager<Int>()
        manager.registerEntity(makeEntity(id: "a"))
        manager.destroy()

        manager.updateEntity(makeEntity(id: "a"))

        XCTAssertNil(manager.getEntity("a"))
        XCTAssertTrue(manager.allEntities().isEmpty)
    }

    /// 読み取り系は例外を投げず、空を返す。
    func testReadsReturnEmptyAfterDestroy() {
        let manager = MarkerManager<Int>()
        manager.registerEntity(makeEntity(id: "a"))
        manager.destroy()

        XCTAssertNil(manager.getEntity("a"))
        XCTAssertFalse(manager.hasEntity("a"))
        XCTAssertNil(manager.removeEntity("a"))
        XCTAssertTrue(manager.allEntities().isEmpty)
        XCTAssertNil(manager.findNearest(position: GeoPoint(latitude: 35.0, longitude: 139.0)))
        XCTAssertTrue(manager.findByIdPrefix("a").isEmpty)
    }

    /// destroy は何度呼んでもよい。
    func testDestroyIsIdempotent() {
        let manager = MarkerManager<Int>()
        manager.registerEntity(makeEntity(id: "a"))
        manager.destroy()
        manager.destroy()

        XCTAssertTrue(manager.isDestroyed)
        XCTAssertTrue(manager.allEntities().isEmpty)
    }

    /// 破棄前は当然ながら通常どおり動く（ガードが常時 false になっていないことの確認）。
    func testNormalOperationBeforeDestroy() {
        let manager = MarkerManager<Int>()
        manager.registerEntity(makeEntity(id: "a"))

        XCTAssertNotNil(manager.getEntity("a"))
        XCTAssertTrue(manager.hasEntity("a"))
        XCTAssertEqual(manager.allEntities().count, 1)
    }
}
