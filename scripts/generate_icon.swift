#!/usr/bin/env swift
//
//  generate_icon.swift
//  Engram - App Icon Generator
//
//  Generates the app icon matching the About tab design
//  Copyright © 2024-2026 Bala Kumar. All rights reserved.
//  https://balakumar.dev
//

import Cocoa
import Foundation

// Icon sizes needed for macOS app icons
let iconSizes: [(size: Int, scale: Int, name: String)] = [
    (16, 1, "icon_16x16"),
    (16, 2, "icon_16x16@2x"),
    (32, 1, "icon_32x32"),
    (32, 2, "icon_32x32@2x"),
    (128, 1, "icon_128x128"),
    (128, 2, "icon_128x128@2x"),
    (256, 1, "icon_256x256"),
    (256, 2, "icon_256x256@2x"),
    (512, 1, "icon_512x512"),
    (512, 2, "icon_512x512@2x")
]

// Theme colors matching the app
let primaryColor = NSColor(red: 0.4, green: 0.5, blue: 1.0, alpha: 1.0)  // Indigo-ish
let secondaryColor = NSColor(red: 0.6, green: 0.4, blue: 0.9, alpha: 1.0)  // Purple-ish

func createIcon(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    
    image.lockFocus()
    
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = CGFloat(size) * 0.22  // ~22% corner radius like macOS icons
    
    // Create gradient
    let gradient = NSGradient(
        starting: primaryColor,
        ending: secondaryColor
    )!
    
    // Draw rounded rectangle with gradient
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    gradient.draw(in: path, angle: -45)  // Top-left to bottom-right
    
    // Draw waveform symbol
    // Using SF Symbols via NSImage
    if let symbolImage = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: nil) {
        let symbolSize = CGFloat(size) * 0.55
        let symbolRect = NSRect(
            x: (CGFloat(size) - symbolSize) / 2,
            y: (CGFloat(size) - symbolSize) / 2,
            width: symbolSize,
            height: symbolSize
        )
        
        // Configure symbol with white color
        let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
        let configuredSymbol = symbolImage.withSymbolConfiguration(config)!
        
        // Tint to white
        let tintedSymbol = NSImage(size: configuredSymbol.size)
        tintedSymbol.lockFocus()
        NSColor.white.set()
        let imageRect = NSRect(origin: .zero, size: configuredSymbol.size)
        configuredSymbol.draw(in: imageRect)
        imageRect.fill(using: .sourceAtop)
        tintedSymbol.unlockFocus()
        
        tintedSymbol.draw(in: symbolRect)
    }
    
    image.unlockFocus()
    
    return image
}

func main() {
    let fileManager = FileManager.default
    let currentDir = fileManager.currentDirectoryPath
    let iconsetPath = "\(currentDir)/AppIcon.iconset"
    
    // Create iconset directory
    try? fileManager.removeItem(atPath: iconsetPath)
    try! fileManager.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)
    
    print("Generating Engram app icon...")
    
    for iconSpec in iconSizes {
        let actualSize = iconSpec.size * iconSpec.scale
        let icon = createIcon(size: actualSize)
        
        // Convert to PNG
        guard let tiffData = icon.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            print("Failed to create PNG for \(iconSpec.name)")
            continue
        }
        
        let filename = "\(iconsetPath)/\(iconSpec.name).png"
        try! pngData.write(to: URL(fileURLWithPath: filename))
        print("  Created \(iconSpec.name).png (\(actualSize)x\(actualSize))")
    }
    
    // Convert iconset to icns
    print("Converting to icns...")
    let icnsPath = "\(currentDir)/AppIcon.icns"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconsetPath, "-o", icnsPath]
    try! process.run()
    process.waitUntilExit()
    
    if process.terminationStatus == 0 {
        print("✓ Created AppIcon.icns")
        // Clean up iconset
        try? fileManager.removeItem(atPath: iconsetPath)
    } else {
        print("✗ Failed to create icns file")
    }
}

main()

