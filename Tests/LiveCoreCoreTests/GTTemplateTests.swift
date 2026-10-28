import Foundation
import XCTest
@testable import LiveCoreCore
@testable import LiveCoreServices

/// 0.39.0: importing vMix GT title templates (.gtzip).
final class GTTemplateTests: XCTestCase {
    // Same shape as a GT save: UTF-8 bytes under an encoding="utf-16" declaration, nested layers.
    static let document = """
    <?xml version="1.0" encoding="utf-16"?>
    <Composition Width="1920" Height="1080">
      <Layer Name="L1" Dimensions="800,100,0" Location="100,900,0" Locked="False">
        <Layer.Composition>
          <Composition Width="400" Height="100">
            <Rectangle Name="Bar" Dimensions="300,50,0" Location="10,20,0" Radius="20,20" StrokeThickness="2">
              <Rectangle.Effects><Effect Type="Skew" Angle="18,0" /></Rectangle.Effects>
              <Rectangle.Fill>
                <Brush Type="LinearGradient" Color="#FFFF0000" StartPoint="0.5,0" EndPoint="0.5,1">
                  <Brush.Stops>
                    <GradientStop Color="#FF000080" />
                    <GradientStop Position="1" Color="#80FF0000" />
                  </Brush.Stops>
                </Brush>
              </Rectangle.Fill>
              <Rectangle.Stroke><Brush Color="#FFFFFFFF" /></Rectangle.Stroke>
            </Rectangle>
          </Composition>
        </Layer.Composition>
      </Layer>
      <Layer Name="L2" Dimensions="1000,200,0" Location="0,0,0" Locked="False">
        <Layer.Composition>
          <Composition Width="1000" Height="200">
            <TextBlock Name="Headline" Dimensions="600,80,0" Location="50,60,0" Text="Berita &quot;Utama&quot;" FontFamily="Helvetica" FontSize="68" FontWeight="Bold" TextAlign="Center" VerticalAlign="Center">
              <TextBlock.Fill><Brush Color="#FF000000" /></TextBlock.Fill>
              <TextBlock.Stroke><Brush Color="#FFFFFFFF" /></TextBlock.Stroke>
            </TextBlock>
            <Text3D Name="Live" Dimensions="180,33,20" Location="700,60,0" Text="LIVE" FontStyle="Italic">
              <Text3D.Effects><Effect Type="Shadow" Offset="5,5" Mode="Shadow" /></Text3D.Effects>
            </Text3D>
            <Image Name="Logo" Dimensions="300,100,0" Location="-50,-10,0">
              <Image.Bitmap><Bitmap Source="abc\\Logo.png" /></Image.Bitmap>
            </Image>
          </Composition>
        </Layer.Composition>
      </Layer>
      <Storyboard>
        <Storyboard.Animations>
          <Reveal Object="Headline" Delay="0.7" />
          <Expand Object="Bar" Delay="0.2" Duration="0.5" Direction="Bottom" />
          <Zoom Object="Logo" Delay="1.8" Duration="0.3" />
        </Storyboard.Animations>
      </Storyboard>
    </Composition>
    """

    func testParsesLayersElementsAndStoryboard() throws {
        let t = GTReader.parse(document: Data(Self.document.utf8)) { $0 == "abc\\Logo.png" ? Data([1, 2, 3]) : nil }
        XCTAssertEqual(t.width, 1920)
        XCTAssertEqual(t.elements.map(\.name), ["Bar", "Headline", "Live", "Logo"])
        let bar = t.elements[0]
        // Layer 800 wide holding a 400 wide composition: x2 horizontally.
        XCTAssertEqual(bar.x, 120); XCTAssertEqual(bar.y, 920)
        XCTAssertEqual(bar.width, 600); XCTAssertEqual(bar.height, 50)
        XCTAssertEqual(bar.skewX, 18)
        XCTAssertEqual(bar.cornerRadius, 20)
        XCTAssertEqual(bar.fill.kind, .linear)
        XCTAssertEqual(bar.fill.stops.count, 2)
        XCTAssertEqual(bar.fill.stops[1].color.a, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(bar.stroke, .white)
        XCTAssertEqual(bar.clip?.width, 800)
        let head = t.elements[1]
        XCTAssertEqual(head.text, "Berita \"Utama\"")
        XCTAssertTrue(head.bold)
        XCTAssertEqual(head.alignment, "Center")
        XCTAssertEqual(head.fill.color, GTColor(r: 0, g: 0, b: 0))
        XCTAssertTrue(t.elements[2].italic)
        XCTAssertEqual(t.elements[2].shadow?.x, 5)
        XCTAssertEqual(t.elements[3].imageData, Data([1, 2, 3]))
        XCTAssertEqual(t.elements[3].x, -50)
        XCTAssertEqual(t.textFields, ["Headline", "Live"])
        XCTAssertEqual(t.animations.count, 3)
        XCTAssertEqual(t.animation(for: "Headline")?.duration, 0.5)
        XCTAssertEqual(t.animation(for: "Bar")?.direction, "Bottom")
        XCTAssertEqual(t.inDuration, 2.1, accuracy: 0.0001)
    }

    func testAnimationFrames() {
        let reveal = GTAnimation(type: "Reveal", object: "a", delay: 1, duration: 1)
        XCTAssertEqual(reveal.progress(at: 0.5), 0)
        XCTAssertEqual(reveal.progress(at: 3), 1)
        XCTAssertEqual(reveal.frame(progress: 0.5).clip.x1, 0.5)
        XCTAssertEqual(GTAnimation(type: "Reveal", object: "a", direction: "Right").frame(progress: 0.25).clip.x0, 0.75)
        let expand = GTAnimation(type: "Expand", object: "a", direction: "Top").frame(progress: 0.5)
        XCTAssertEqual(expand.scale.y, 0.5); XCTAssertEqual(expand.anchor.y, 0)
        XCTAssertEqual(GTAnimation(type: "Zoom", object: "a").frame(progress: 0.4).scale.x, 0.4)
    }

    func testUTF16DocumentAndHexColors() {
        var data = Data([0xFF, 0xFE])
        data.append(Self.document.data(using: .utf16LittleEndian)!)
        XCTAssertEqual(GTReader.parse(document: data).elements.count, 4)
        XCTAssertEqual(GTColor(hex: "#FF0000"), GTColor(r: 1, g: 0, b: 0))
        XCTAssertNil(GTColor(hex: "red"))
    }

    func testReadsGTZipWithResources() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString)/src")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(Self.document.utf8).write(to: dir.appendingPathComponent("document.xml"))
        try Data(#"<resources><resource filename="abc\Logo.png"><source guid="1111-2222">abc\Logo.png</source></resource></resources>"#.utf8)
            .write(to: dir.appendingPathComponent("resources.xml"))
        try Data([9, 8, 7]).write(to: dir.appendingPathComponent("1111-2222"))
        let out = dir.deletingLastPathComponent().appendingPathComponent("t.gtzip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-q", out.path, "document.xml", "resources.xml", "1111-2222"]
        try zip.run(); zip.waitUntilExit()
        let t = try GTReader.template(at: out)
        XCTAssertEqual(t.elements.first { $0.kind == .image }?.imageData, Data([9, 8, 7]))
        let bad = dir.appendingPathComponent("bad.gtzip")
        try Data("nope".utf8).write(to: bad)
        XCTAssertThrowsError(try GTReader.template(at: bad))
    }

    func testProjectSourceRoundTrip() throws {
        let s = ProjectSource.gtTitle(ProjectGTTitle(file: ProjectMediaRef(path: "/t/a.gtzip", relativePath: "a.gtzip"),
                                                     fields: ["Headline": "Halo"]))
        XCTAssertEqual(try JSONDecoder().decode(ProjectSource.self, from: JSONEncoder().encode(s)), s)
    }
}
