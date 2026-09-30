// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name:"Chillor",
    platforms:[.macOS(.v15)],
    products:[.executable(name:"Chillor",targets:["Chillor"])],
    dependencies:[.package(path:"Vendor/swift-markdown-ui")],
    targets:[.systemLibrary(name:"CSQLite"),.executableTarget(name:"Chillor",dependencies:["CSQLite",.product(name:"MarkdownUI",package:"swift-markdown-ui")],swiftSettings:[.swiftLanguageMode(.v5)])]
)
