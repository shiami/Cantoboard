//
//  PadFull4RowsKeyboardViewLayout.swift
//  CantoboardFramework
//
//  Created by Alex Man on 9/6/21.
//

import Foundation

import Foundation
import UIKit

class PadFull4RowsKeyboardViewLayout : KeyboardViewLayout {
    static let numOfRows = 4
    
    static let letters: [[[KeyCap]]] = [
        [["\t", "q", "w", "e", "r", "t", "y", "u", "i", "o", "p", .backspace]],
        [[.capsLock, "a", "s", "d", "f", "g", "h", "j", "k", "l", .returnKey(.default)]],
        [[.shift(.lowercased), "z", "x", "c", "v", "b", "n", "m", ",", ".", .shift(.lowercased)]],
        [[.nextKeyboard, .keyboardType(.numeric), .contextualSymbols(.english)], [.space(.space)], [.keyboardType(.numeric), .dismissKeyboard]]
    ]
    
    static let numbersHalf: [[[KeyCap]]] = [
        [["\t", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", .backspace]],
        [[.placeholder(.capsLock), "@", "#", "$", "&", "*", "(", ")", "’", "”", .returnKey(.default)]],
        [[.keyboardType(.symbolic), "%", "-", "+", "=", "/", ";", ":", ",", ".", .keyboardType(.symbolic)]],
        [[.nextKeyboard, .keyboardType(.alphabetic(.lowercased)), .contextualSymbols(.english)], [.space(.space)], [.keyboardType(.alphabetic(.lowercased)), .dismissKeyboard]]
    ]
    
    // FIXME
    static let numbersFull: [[[KeyCap]]] = [
        [["\t", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", .backspace]],
        [[.placeholder(.capsLock), "@", "#", "$", "&", "*", "(", ")", "’", "”", .returnKey(.default)]],
        [[.keyboardType(.symbolic), "%", "-", "+", "=", "/", ";", ":", ",", ".", .keyboardType(.symbolic)]],
        [[.nextKeyboard, .keyboardType(.alphabetic(.lowercased)), .contextualSymbols(.english)], [.space(.space)], [.keyboardType(.alphabetic(.lowercased)), .dismissKeyboard]]
    ]
    
    static let symbolsHalf: [[[KeyCap]]] = [
        [["\t", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", .backspace]],
        [[.placeholder(.capsLock), "€", "£", "¥", "_", "^", "[", "]", "{", "}", .returnKey(.default)]],
        [[.keyboardType(.numeric), "§", "|", "~", "…", "\\", "<", ">", "!", "?", .keyboardType(.numeric)]],
        [[.nextKeyboard, .keyboardType(.alphabetic(.lowercased)), .contextualSymbols(.english)], [.space(.space)], [.keyboardType(.alphabetic(.lowercased)), .dismissKeyboard]]
    ]
    
    // FIXME
    static let symbolsFull: [[[KeyCap]]] = [
        [["\t", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", .backspace]],
        [[.placeholder(.capsLock), "€", "£", "¥", "_", "^", "[", "]", "{", "}", .returnKey(.default)]],
        [[.keyboardType(.numeric), "§", "|", "~", "…", "\\", "<", ">", "!", "?", .keyboardType(.numeric)]],
        [[.nextKeyboard, .keyboardType(.alphabetic(.lowercased)), .contextualSymbols(.english)], [.space(.space)], [.keyboardType(.alphabetic(.lowercased)), .dismissKeyboard]]
    ]
    
    static func layoutKeyViews(keyRowView: KeyRowView, leftKeys: [KeyView], middleKeys: [KeyView], rightKeys: [KeyView], layoutConstants: LayoutConstants) -> [CGRect] {
        let directionalLayoutMargins = keyRowView.directionalLayoutMargins
        let bounds = keyRowView.bounds
        
        let availableWidth = bounds.width - directionalLayoutMargins.leading - directionalLayoutMargins.trailing
        
        let allKeys = leftKeys + middleKeys + rightKeys
        
        var numFlexibleWidthKeys: Int = 0
        var keyWidths = Dictionary<KeyView, CGFloat>()
        
        let takenWidth = getFixedKeyWidth(keys: allKeys, layoutConstants: layoutConstants, numFlexibleWidthKeys: &numFlexibleWidthKeys, keyWidths: &keyWidths)
        
        let totalGapWidth = CGFloat(allKeys.count - 1) * layoutConstants.buttonGapX
        let flexibleKeyWidth = (availableWidth - takenWidth - totalGapWidth) / CGFloat(numFlexibleWidthKeys)
        
        var allFrames: [CGRect]
        var x = directionalLayoutMargins.leading
        
        allFrames = layoutKeys(keys: allKeys, keyWidths: keyWidths, flexibleKeyWidth: flexibleKeyWidth, buttonGapX: layoutConstants.buttonGapX, keyHeight: layoutConstants.keyHeight, marginTop: directionalLayoutMargins.top, x: &x)
        
        return allFrames
    }
    
    private static func layoutKeys(keys: [KeyView], keyWidths: Dictionary<KeyView, CGFloat>, flexibleKeyWidth: CGFloat, buttonGapX: CGFloat, keyHeight: CGFloat, marginTop: CGFloat, x: inout CGFloat) -> [CGRect] {
        return keys.map { key in
            let keyWidth = keyWidths[key, default: flexibleKeyWidth]
            let rect = CGRect(x: x, y: marginTop, width: keyWidth, height: keyHeight)
            x += rect.width + buttonGapX
            
            return rect
        }
    }
    
    private static func getFixedKeyWidth(keys: [KeyView], layoutConstants: LayoutConstants, numFlexibleWidthKeys: inout Int, keyWidths: inout Dictionary<KeyView, CGFloat>) -> CGFloat {
        let padFull4RowsLayoutConstants = layoutConstants.padFull4RowsLayoutConstants!
        
        let totalFixedKeyWidth = keys.enumerated().reduce(CGFloat(0)) {sum, indexAndKey in
            let index = indexAndKey.offset
            let key = indexAndKey.element
            
            var width: CGFloat
            switch key.keyCap {
            case "\t", .backspace: width = padFull4RowsLayoutConstants.tabDeleteKeyWidth
            case .capsLock: width = padFull4RowsLayoutConstants.capLockKeyWidth
            case .shift:
                if index == 0 {
                    width = padFull4RowsLayoutConstants.leftShiftKeyWidth
                } else {
                    width = padFull4RowsLayoutConstants.rightShiftKeyWidth
                }
            case .returnKey: width = padFull4RowsLayoutConstants.returnKeyWidth
            case .nextKeyboard, .contextualSymbols,
                 .keyboardType where index <= 2:
                width = padFull4RowsLayoutConstants.leftSystemKeyWidth
            case .keyboardType, .dismissKeyboard:
                width = padFull4RowsLayoutConstants.rightSystemKeyWidth
            default:
                width = 0
                numFlexibleWidthKeys += 1
            }
            
            if width > 0 {
                keyWidths[key] = width
            }
            
            return sum + width
        }
        
        return totalFixedKeyWidth
    }
    
    static func getKeyHeight(atRow: Int, layoutConstants: LayoutConstants) -> CGFloat {
        return layoutConstants.keyHeight
    }
}