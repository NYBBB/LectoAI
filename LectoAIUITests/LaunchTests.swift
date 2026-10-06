import XCTest
import AppKit

/// 界面冒烟测试。全部使用 Debug 演示数据或隔离的临时资料库，不读写真实课堂记录。
/// --demo-front 让窗口保持在最前，避免台前调度把窗口收成缩略图导致无法点击；截图由人工自查另行完成
/// （临时签名的测试运行器每次重建都会失去屏幕录制授权，XCTest 截图会失败）。
@MainActor
final class LaunchTests: XCTestCase {
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        // 把会影响结果的偏好用启动参数固定下来：测试不依赖、也不改动真实使用时的设置。
        app.launchArguments = arguments + ["--demo-front", "-ApplePersistenceIgnoreState", "YES", "-appearance", "light",
                                           "-autoExport", "YES", "-autoExportAudio", "NO", "-exportAudio", "NO",
                                           "-exportTemplate", "{date} {title}", "-semesterStart", "0"]
        app.launch()
        return app
    }

    func testStartScreenDoesNotStartCapture() {
        let app = launch(["--demo-start"])
        XCTAssertTrue(app.buttons["startListening"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["暂停"].exists)
        XCTAssertTrue(app.staticTexts["准备情况"].exists)
        app.terminate()
    }

    func testLiveClassroomMarksAndNotes() {
        let app = launch(["--demo", "-showAssistant", "NO"])
        XCTAssertTrue(app.buttons["markConfused"].waitForExistence(timeout: 10))
        // 底部栏使用玻璃材质，XCTest 的可点击判断偶尔误报；按坐标点击同一个按钮。
        app.buttons["markConfused"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "已标记", "已标记")).firstMatch.waitForExistence(timeout: 5))
        let composer = app.textFields["noteComposer"]
        XCTAssertTrue(composer.exists)
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        composer.typeText("Remember: exec never returns on success\r")
        let saved = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "exec never returns on success", "exec never returns on success")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        app.terminate()
    }

    func testReviewShowsSavedBannerAndPlayback() {
        let app = launch(["--demo-review"])
        XCTAssertTrue(app.buttons["playbackToggle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "已保存", "已保存")).firstMatch.exists)
        // 从课堂记录里点进一堂课后，左下角“新课堂”回到开始页。
        app.buttons["newLesson"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.buttons["startListening"].waitForExistence(timeout: 5))
        app.terminate()
    }

    /// 中文模式字幕很长时，越出顶部的文字不能盖住小窗顶部按钮（0.3.3 课堂实测问题）。
    func testFloatingPinToggleWithLongChineseCaptions() {
        let app = launch(["--demo", "--demo-floating", "--demo-hover", "-floatingReadingMode", "chinese", "-floatingScale", "1.6"])
        let pin = app.buttons["floatingPin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 10))
        let before = pin.value as? String
        pin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let changed = NSPredicate(format: "value != %@", before ?? "")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: changed, evaluatedWith: pin)], timeout: 3), .completed, "图钉被字幕挡住，点击无效")
        // 测试与真实使用共用偏好设置：点回原状态，不改动用户的置顶选择。
        pin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == %@", before ?? ""), evaluatedWith: pin)], timeout: 3), .completed)
        app.terminate()
    }

    /// 小窗总结模式：显示总结文章；往上滚动后出现“最新”，点它回到底部继续跟随。
    func testFloatingSummaryScrollsAndReturnsToLatest() {
        let app = launch(["--demo", "--demo-floating", "--demo-hover", "-floatingReadingMode", "summary", "-floatingScale", "1.75"])
        let latest = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "close-on-exec", "close-on-exec")).firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 10), "小窗总结模式没有显示文章")
        let panel = app.descendants(matching: .any)["captionPanel"].firstMatch
        let scroll = panel.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists, "小窗内容应可滚动")
        scroll.scroll(byDeltaX: 0, deltaY: 400)
        let back = app.buttons["floatingLatest"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "往上滚动后应出现“最新”按钮")
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: back)], timeout: 5), .completed)
        app.terminate()
    }

    /// 导出面板：手动命名、取消勾选几个文件后导出到其他位置；再次打开时记住勾选与这堂课的名字，并能恢复按模板命名。
    /// 演示模式下勾选与命名只放在内存里（初始为全选、按模板命名），不读也不改真实使用时的导出偏好；
    /// 导出写进 App 自己的临时目录。“只写选中的文件、按输入的名字命名”由核心测试 testManagedExportSelectedFilesWithCustomName 覆盖。
    func testExportSheetSelectedFilesAndName() {
        let app = launch(["--demo-review", "--demo-export-dir", "auto"])
        XCTAssertTrue(app.buttons["playbackToggle"].waitForExistence(timeout: 10))
        // 从菜单打开导出面板：合成的 ⇧⌘E 按键在测试环境里不一定送达（2026-10-05 首次运行本测试时发现）。
        func openExport() {
            app.menuBars.menuBarItems["文件"].click()
            app.menuItems["导出…"].click()
        }
        openExport()
        let name = app.textFields["exportName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "导出面板没有打开")
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Week 5 测试")
        // 分组表单里的开关在不同系统版本上可能是复选框或开关，按标识符找。
        let vtt = app.descendants(matching: .any)["exportFile-课堂转录.vtt"].firstMatch
        let info = app.descendants(matching: .any)["exportFile-记录信息.md"].firstMatch
        XCTAssertTrue(vtt.exists && info.exists)
        func isOn(_ element: XCUIElement) -> Bool { (element.value as? Int) == 1 || (element.value as? String) == "1" }
        XCTAssertTrue(isOn(vtt) && isOn(info), "演示模式下应从全选开始")
        vtt.click(); info.click()
        XCTAssertFalse(isOn(vtt) || isOn(info), "点击后应取消勾选")
        XCTAssertEqual(name.value as? String, "Week 5 测试", "名字没有输入进去")
        app.buttons["exportConfirm"].click()
        let exported = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "已导出到", "已导出到")).firstMatch
        let failed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "导出失败", "导出失败")).firstMatch
        XCTAssertTrue(exported.waitForExistence(timeout: 10), "导出后没有提示")
        XCTAssertFalse(failed.exists, "导出失败")
        // 再次打开：记住了勾选与名字；然后恢复按模板命名。
        openExport()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Week 5 测试")
        XCTAssertFalse(isOn(vtt), "应记住上次没勾选字幕文件")
        // 链接样式的按钮不一定被归为按钮类型，按标识符找。
        let restore = app.descendants(matching: .any)["exportRestoreName"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 3), "改过名字后应提供恢复按模板命名")
        restore.click()
        XCTAssertNotEqual(name.value as? String, "Week 5 测试", "没有恢复成按模板命名")
        app.buttons["exportConfirm"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: name)], timeout: 5), .completed)
        app.terminate()
    }

    func testFloatingCaptionPanel() {
        let app = launch(["--demo", "--demo-floating", "--demo-hover"])
        XCTAssertTrue(app.descendants(matching: .any)["captionPanel"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["floatingMarkConfused"].exists)
        app.terminate()
    }

    /// 窗口宽度偏离默认尺寸时曾因约束死循环崩溃（0.3.1）：以较窄的记忆尺寸启动三种页面，App 必须保持运行。
    func testNarrowWindowDoesNotCrash() {
        for mode in ["--demo", "--demo-review", "--demo-start"] {
            let app = launch([mode, "-NSWindow Frame LectoAIMainWindow", "100 100 900 600 0 0 1710 1074"])
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 2)
            XCTAssertNotEqual(app.state, .notRunning, "窄窗口启动后崩溃：\(mode)")
            app.terminate()
        }
    }

    /// 侧栏搜索按课名过滤；回看未整理的课堂直接给出整理按钮。
    func testSidebarSearchAndDigestPrompt() {
        let app = launch(["--demo-review"])
        XCTAssertTrue(app.buttons["makeDigest"].waitForExistence(timeout: 10) || app.buttons["整理这堂课的纪要"].exists)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("特征值")
        let math = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "MATH 2114", "MATH 2114")).firstMatch
        XCTAssertTrue(math.waitForExistence(timeout: 5))
        let other = app.outlines.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "信号与管道", "信号与管道")).firstMatch
        XCTAssertFalse(other.exists, "搜索后不相关的课堂应被过滤")
        app.terminate()
    }

    /// 开始页按以往上课时间认出课程；没有课程时只有一个“现在选”，不挡开始。
    func testStartPageRecognizesCourse() {
        let app = launch(["--demo-start", "--demo-courses"])
        XCTAssertTrue(app.buttons["startListening"].waitForExistence(timeout: 10))
        let picker = app.descendants(matching: .any)["coursePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "开始页没有课程选择")
        // 菜单按钮的文字可能出现在 label、title 或 value 里，取决于系统如何暴露无边框菜单。
        let recognized = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR title CONTAINS %@ OR value CONTAINS %@", "CS 3214", "CS 3214", "CS 3214")).firstMatch
        XCTAssertTrue(recognized.waitForExistence(timeout: 5), "没有按以往时间认出课程：\(picker.debugDescription)")
        app.terminate()
    }

    /// 下课时拿不准是哪门课：横幅询问，有建议的那门排第一；点一下就归课并交到（演示模式写进临时目录）。
    func testFinishBannerAsksCourseThenHandsOff() {
        let app = launch(["--demo-review", "--demo-courses", "--demo-finish", "ask"])
        let question = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "这堂课是哪门课", "这堂课是哪门课")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 10), "没有询问归到哪门课")
        let suggested = app.buttons["courseChip-suggested"]
        XCTAssertTrue(suggested.exists, "应把按时间建议的课程排在第一个")
        suggested.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let delivered = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "已交到“CS 3214”", "已交到“CS 3214”")).firstMatch
        XCTAssertTrue(delivered.waitForExistence(timeout: 10), "点了课程之后没有交接")
        XCTAssertFalse(question.exists)
        app.terminate()
    }

    /// 就地新建课程：确认卡里名称已经填好，点“完成”即建课、归课并交接。
    func testNewCourseCardCreatesCourseAndHandsOff() {
        let app = launch(["--demo-review", "--demo-courses", "--demo-finish", "new"])
        let name = app.textFields["newCourseName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "确认卡没有出现")
        XCTAssertEqual(name.value as? String, "CS3214")
        app.buttons["newCourseConfirm"].click()
        let delivered = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "已交到“CS3214”", "已交到“CS3214”")).firstMatch
        XCTAssertTrue(delivered.waitForExistence(timeout: 10), "建课后没有把这堂课交过去")
        app.terminate()
    }

    func testDarkAppearance() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-front", "-ApplePersistenceIgnoreState", "YES", "-appearance", "dark"]
        app.launch()
        XCTAssertTrue(app.buttons["markConfused"].waitForExistence(timeout: 10))
        app.terminate()
    }

    func testCapabilityChecksDoNotStartCapture() {
        let app = launch(["--demo-start"])
        app.menuBars.menuBarItems["开发"].click()
        app.menuItems["本机能力检查…"].click()
        let probe = app.windows["本机能力检查"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        XCTAssertTrue(probe.buttons["麦克风试音"].isEnabled)
        XCTAssertFalse(probe.buttons["停止试音"].isEnabled)
        app.terminate()
    }

    /// 真实识别与翻译：把合成英语放进 App 沙盒临时目录后导入（按实际时长处理）。本机未准备语言资源时跳过。
    func testRealSpeechImportShowsParagraphTranslation() throws {
        let source = URL(fileURLWithPath: "/tmp/LectoAI-EnglishSmoke.aiff")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("按 README 生成合成语音后再运行音频烟测。") }
        let container = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.lectoai.mac.dev/Data/tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let target = container.appendingPathComponent("LectoAI-EnglishSmoke.aiff")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
        let app = launch(["--test-workspace", "--import-file", target.path, "-readingMode", "bilingual"])
        let english = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "greedy", "greedy")).firstMatch
        guard english.waitForExistence(timeout: 45) else {
            throw XCTSkip("没有识别出文字：请先在“设置 → 识别与翻译”准备英语识别资源。")
        }
        let chinese = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "算法", "算法")).firstMatch
        XCTAssertTrue(chinese.waitForExistence(timeout: 45))
        XCTAssertTrue(app.buttons["playbackToggle"].waitForExistence(timeout: 30))
        app.terminate()
    }
}
