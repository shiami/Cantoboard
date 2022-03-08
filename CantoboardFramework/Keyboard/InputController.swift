//
//  InputHandler.swift
//  CantoboardFramework
//
//  Created by Alex Man on 1/26/21.
//

import Foundation
import UIKit

import CocoaLumberjackSwift
import ZIPFoundation

enum KeyboardEnableState: Equatable {
    case enabled, disabled, loading
}

indirect enum ContextualType: Equatable {
    case english, chinese, rime(languageContext: ContextualType), url
    
    var halfWidthSymbol: Bool {
        switch self {
        case .chinese, .rime(.chinese): return false
        default: return true
        }
    }
}

struct KeyboardState: Equatable {
    var keyboardType: KeyboardType {
        didSet {
            if case .alphabetic = keyboardType {
                symbolShapeOverride = nil
            }
        }
    }
    var lastKeyboardTypeChangeFromAutoCap: Bool
    var isComposing: Bool
    var keyboardContextualType: ContextualType
    var symbolShapeOverride: SymbolShape?
    var specialSymbolShapeOverride: [SpecialSymbol: SymbolShape?]

    var isPortrait: Bool
    
    var enableState: KeyboardEnableState
    
    var returnKeyType: ReturnKeyType
    var needsInputModeSwitchKey: Bool
    var spaceKeyMode: SpaceKeyMode
    
    var isKeyboardAppearing: Bool
    
    var keyboardIdiom: LayoutIdiom
    
    var mainSchema: RimeSchema, reverseLookupSchema: RimeSchema?
    var inputMode: InputMode {
        didSet { SessionState.main.lastInputMode = inputMode }
    }
    
    var activeSchema: RimeSchema {
        get { reverseLookupSchema ?? mainSchema }
    }
    
    var symbolShape: SymbolShape {
        symbolShapeOverride ?? (!keyboardContextualType.halfWidthSymbol ? .full : .half)
    }
    
    var shouldUseKeypad: Bool {
        if activeSchema.isKeypadBased && inputMode != .english,
           case .alphabetic = keyboardType {
            return true
        }
        return false
    }
    
    var filters: [String]?
    var selectedFilterIndex: Int?
    
    var showCommonSwipeDownKeysInLongPress: Bool {
        keyboardIdiom == .phone
    }
    
    init() {
        keyboardType = KeyboardType.alphabetic(.lowercased)
        lastKeyboardTypeChangeFromAutoCap = false
        isComposing = false
        keyboardContextualType = .english
        specialSymbolShapeOverride = [:]
        let layoutConstants = LayoutConstants.forMainScreen
        isKeyboardAppearing = false
        keyboardIdiom = layoutConstants.idiom
        isPortrait = layoutConstants.isPortrait
        
        enableState = .enabled
        
        returnKeyType = .default
        needsInputModeSwitchKey = false
        spaceKeyMode = .space
        
        mainSchema = SessionState.main.lastPrimarySchema
        inputMode = SessionState.main.lastInputMode
    }
}

class InputController: NSObject {
    private let c = InstanceCounter<InputController>()
    
    private weak var keyboardViewController: KeyboardViewController?
    private(set) var inputEngine: BilingualInputEngine!
    private var compositionRenderer: CompositionRenderer!
    private(set) var isImmediateMode: Bool!
    
    private(set) var state: KeyboardState = KeyboardState()
    
    private var lastKey: KeyboardAction?
    private var isHoldingShift = false
        
    private var hasInsertedAutoSpace = false
    private var shouldApplyChromeSearchBarHack = false
    private var needClearInput = false, needReloadCandidates = false
    
    private var autoSuggestionTypeOverride: AutoSuggestionType?
    private var replaceTextLen = 0;

    private var prevTextBefore: String?
    
    private(set) var candidateOrganizer: CandidateOrganizer!

    var textDocumentProxy: UITextDocumentProxy? {
        keyboardViewController?.textDocumentProxy
    }
    
    private var documentContextBeforeInput: String {
        compositionRenderer.textBeforeInput
    }
    
    private var documentContextAfterInput: String {
        compositionRenderer.textAfterInput
    }
    
    init(keyboardViewController: KeyboardViewController) {
        super.init()
        
        self.keyboardViewController = keyboardViewController
        inputEngine = BilingualInputEngine(inputController: self, rimeSchema: state.mainSchema)
        candidateOrganizer = CandidateOrganizer(inputController: self)
        
        refreshInputSettings()
    }
    
    func prepare() {
        inputEngine.prepare()
        needReloadCandidates = true
        
        state.isKeyboardAppearing = true
        updateInputState()
    }
    
    func unprepare() {
        state.isKeyboardAppearing = false
        keyboardViewController?.state = state
    }
    
    func textWillChange(_ textInput: UITextInput?) {
        prevTextBefore = compositionRenderer.textBeforeInput
        // DDLogInfo("textWillChange prevTextBefore '\(prevTextBefore ?? "nil")' doc '\(textDocumentProxy?.documentContextBeforeInput ?? "nil")'")
    }
    
    func textDidChange(_ textInput: UITextInput?) {
        // DDLogInfo("textDidChange prevTextBefore '\(prevTextBefore ?? "nil")' textBeforeInput '\(compositionRenderer.textBeforeInput)' doc '\(textDocumentProxy?.documentContextBeforeInput ?? "nil")'")
        shouldApplyChromeSearchBarHack = isTextFieldWebSearch() && !isImmediateMode
        
        let textBeforeInput = compositionRenderer.textBeforeInput
        if !isImmediateMode && isTextFieldWebSearch() && prevTextBefore != textBeforeInput && !textBeforeInput.isEmpty {
            // Attempt to fix https://github.com/Cantoboard/Cantoboard/issues/33
            // !textBeforeInput.isEmpty is added to fix address typing in Chrome. Without this fix, the first input letter is ignored.
            clearInput()
            prevTextBefore = textBeforeInput
        }
        
        updateInputState()
    }
    
    private func updateContextualSuggestion() {
        checkAutoCap()
        refreshKeyboardContextualType()
        showAutoSuggestCandidates()
    }
    
    private func candidateSelected(choice: IndexPath, enableSmartSpace: Bool) {
        if let commitedText = candidateOrganizer.selectCandidate(indexPath: choice) {
            if candidateOrganizer?.autoSuggestionType?.replaceTextOnInsert ?? false {
                textDocumentProxy?.deleteBackward(times: replaceTextLen)
                replaceTextLen = 0
                if candidateOrganizer?.autoSuggestionType == .keypadSymbols {
                    // If we are inserting pairs e.g. bracket, move the caret inside the pair.
                    insertText(commitedText, requestSmartSpace: enableSmartSpace)
                    if commitedText.count == 2 && commitedText.char(at: 0) != commitedText.char(at: 1) {
                        textDocumentProxy?.adjustTextPosition(byCharacterOffset: -1)
                    }
                    return
                }
            }
            if commitedText.allSatisfy({ $0.isEnglishLetter }) {
                EnglishInputEngine.userDictionary.learnWord(word: commitedText)
            }
            insertText(commitedText, requestSmartSpace: enableSmartSpace)
            if !candidateOrganizer.shouldCloseCandidatePaneOnCommit {
                keyboardViewController?.keyboardView?.changeCandidatePaneMode(.row)
            }
        }
    }
    
    private func candidateLongPressed(choice: IndexPath) {
        if let text = candidateOrganizer.getCandidate(indexPath: choice), text.allSatisfy({ $0.isEnglishLetter }) {
            if EnglishInputEngine.userDictionary.unlearnWord(word: text) {
                FeedbackProvider.lightImpact.impactOccurred()
                let candidateCount = candidateOrganizer.getCandidateCount(section: choice.section)
                inputEngine.updateEnglishCandidates()
                candidateOrganizer.updateCandidates(reload: true, targetCandidatesCount: candidateCount)
            }
        }
    }
    
    private func handleSpace(spaceKeyMode: SpaceKeyMode) {
        guard let textDocumentProxy = textDocumentProxy else { return }
        
        let hasCandidate = inputEngine.isComposing && candidateOrganizer.getCandidateCount(section: 0) > 0
        switch spaceKeyMode {
        case .nextPage where hasCandidate:
            keyboardViewController?.keyboardView?.scrollCandidatePaneToNextPageInRowMode()
            needReloadCandidates = false
        case .select where hasCandidate:
            candidateSelected(choice: [0, 0], enableSmartSpace: true)
        case .fullWidthSpace:
            if !insertComposingText(appendBy: "　", shouldDisableSmartSpace: true) {
                insertText("　")
            }
        default:
            if !insertComposingText() {
                if !handleAutoSpace() {
                    textDocumentProxy.insertText(" ")
                }
            }
        }
    }
    
    private func handleQuote(isDoubleQuote: Bool) {
        let openingChar: Character = isDoubleQuote ? "“" : "‘"
        let closingChar: Character = isDoubleQuote ? "”" : "’"

        let textBeforeInput: String
        if inputEngine.isComposing {
            textBeforeInput = documentContextBeforeInput + (inputEngine.composition?.text ?? "")
        } else {
            textBeforeInput = documentContextBeforeInput
        }

        let lastOpenCharIndex = textBeforeInput.lastIndex(of: openingChar)
        let lastClosingCharIndex = textBeforeInput.lastIndex(of: closingChar)

        let quote: String
        if keyboardViewController?.textDocumentProxy.smartQuotesType ?? .default == .no {
            quote = isDoubleQuote ? "\"" : "'"
        } else if !isDoubleQuote && !(textBeforeInput.last?.isWhitespace ?? true) {
            // iOS default keyboard uses right single quote as apostrophe
            quote = String(closingChar)
        } else if lastOpenCharIndex != nil && lastClosingCharIndex == nil {
            // prev context has just opening quote.
            quote = String(closingChar)
        } else if
            let lastOpenCharIndex = lastOpenCharIndex,
            let lastClosingCharIndex = lastClosingCharIndex,
            textBeforeInput.distance(from: lastClosingCharIndex, to: lastOpenCharIndex) > 0 {
            // prev context has opening quotes & closing quotes.
            quote = String(closingChar)
        } else {
            quote = String(openingChar)
        }

        if !insertComposingText(appendBy: quote) {
            insertText(quote)
        }
    }
    
    private var cachedActions: [KeyboardAction] = []
    
    func reenableKeyboard() {
        DispatchQueue.main.async { [self] in
            guard RimeApi.shared.state == .succeeded else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: reenableKeyboard)
                return
            }
            DDLogInfo("Enabling keyboard.")
            cachedActions.forEach({ self.handleKey($0) })
            cachedActions = []
            state.enableState = .enabled
            keyboardViewController?.state = state
        }
    }
    
    func keyboardDisappeared() {
        compositionRenderer.textReset()
        clearInput()
    }
    
    func onLayoutChanged() {
        guard let newLayoutConstants = keyboardViewController?.layoutConstants.ref else { return }
        state.keyboardIdiom = newLayoutConstants.idiom
        state.isPortrait = newLayoutConstants.isPortrait

        keyboardViewController?.state = state
    }
    
    func handleKey(_ action: KeyboardAction) {
        guard RimeApi.shared.state == .succeeded else {
            // If RimeEngine isn't ready, disable the keyboard.
            DDLogInfo("Disabling keyboard")
            state.enableState = .loading
            cachedActions.append(action)
            keyboardViewController?.state = state
            return
        }
        
        guard let textDocumentProxy = textDocumentProxy else { return }
        
        defer {
            lastKey = action
            keyboardViewController?.state = state
        }
        
        needClearInput = false
        needReloadCandidates = true
        let isComposing = inputEngine.isComposing
        var hasMutatedComposition = false
        
        switch action {
        case .moveCursorForward, .moveCursorBackward:
            moveCursor(offset: action == .moveCursorBackward ? -1 : 1)
            hasMutatedComposition = true
        case .character(let c):
            guard let char = c.first else { return }
            if !isComposing && shouldApplyChromeSearchBarHack {
                // To clear out the current url selected in Chrome address bar.
                // This shouldn't have any side effects in other apps.
                textDocumentProxy.insertText("")
            }
            let shouldFeedCharToInputEngine = char.isEnglishLetter && c.count == 1
            if !(shouldFeedCharToInputEngine && inputEngine.processChar(char)) {
                if !insertComposingText(appendBy: c) {
                    insertText(c)
                }
            }
            if !isHoldingShift && state.keyboardType == .some(.alphabetic(.uppercased)) {
                state.keyboardType = .alphabetic(.lowercased)
                state.lastKeyboardTypeChangeFromAutoCap = false
            }
            hasMutatedComposition = true
        case .rime(let rc):
            guard isComposing || rc == .sym else { return }
            _ = inputEngine.processRimeChar(rc.rawValue)
            hasMutatedComposition = true
        case .space(let spaceKeyMode):
            handleSpace(spaceKeyMode: spaceKeyMode)
            hasMutatedComposition = true
        case .quote(let isDoubleQuote):
            handleQuote(isDoubleQuote: isDoubleQuote)
            hasMutatedComposition = true
        case .newLine:
            if !insertComposingText(shouldDisableSmartSpace: true) || isImmediateMode {
                let shouldApplyBrowserYoutubeSearchHack = textDocumentProxy.returnKeyType == .search && !isImmediateMode
                if shouldApplyBrowserYoutubeSearchHack {
                    // This is a special hack for triggering finishing/search event with marked text in browser searching on www.youtube.com
                    textDocumentProxy.unmarkText()
                    DispatchQueue.main.async {
                        textDocumentProxy.insertText("\n")
                    }
                } else {
                    insertText("\n")
                }
            }
            hasMutatedComposition = true
        case .backspace, .deleteWord, .deleteWordSwipe:
            if action == .backspace && state.selectedFilterIndex != nil {
                state.selectedFilterIndex = nil
            } else if state.reverseLookupSchema != nil && !isComposing {
                clearInput(shouldLeaveReverseLookupMode: true)
                hasMutatedComposition = true
            } else if isComposing {
                if action == .deleteWordSwipe {
                    needClearInput = true
                } else {
                    if isTextFieldWebSearch() && isImmediateMode {
                        // To clear out the auto complete suggestion in Chrome url bar.
                        // Without this hack, deleteBackward() call will only remove the autosuggestion. It won't remove the the last char of the input.
                        // This shouldn't have any side effects in other apps.
                        textDocumentProxy.insertText(" ")
                        textDocumentProxy.deleteBackward()
                    }
                    _ = inputEngine.processBackspace()
                }
                if !inputEngine.isComposing {
                    keyboardViewController?.keyboardView?.changeCandidatePaneMode(.row)
                }
                hasMutatedComposition = true
            } else {
                switch action {
                case .backspace: textDocumentProxy.deleteBackward()
                case .deleteWord: textDocumentProxy.deleteBackwardWord()
                case .deleteWordSwipe:
                    if textDocumentProxy.documentContextBeforeInput?.last?.isASCII ?? false {
                        textDocumentProxy.deleteBackwardWord()
                    } else {
                        textDocumentProxy.deleteBackward()
                    }
                default:()
                }
                hasMutatedComposition = true
            }
        case .emoji(let e):
            FeedbackProvider.play(keyboardAction: action)
            if !insertComposingText(appendBy: e, shouldDisableSmartSpace: true) {
                textDocumentProxy.insertText(e)
            }
            hasMutatedComposition = true
        case .shiftDown:
            isHoldingShift = true
            state.keyboardType = .alphabetic(.uppercased)
            state.lastKeyboardTypeChangeFromAutoCap = false
            updateSpaceState()
            return
        case .shiftUp:
            state.keyboardType = .alphabetic(.lowercased)
            state.lastKeyboardTypeChangeFromAutoCap = false
            isHoldingShift = false
            updateSpaceState()
            return
        case .shiftRelax:
            isHoldingShift = false
            return
        case .keyboardType(let type):
            state.keyboardType = type
            state.lastKeyboardTypeChangeFromAutoCap = false
            checkAutoCap()
            updateSpaceState()
            refreshInputSettings()
            return
        case .setCharForm(let cs):
            inputEngine.charForm = cs
            let currentCandidatesCount = candidateOrganizer.getCandidateCount(section: 0)
            keyboardViewController?.keyboardView?.setPreserveCandidateOffset()
            candidateOrganizer.charForm = cs
            candidateOrganizer.updateCandidates(reload: true, targetCandidatesCount: currentCandidatesCount)
            return
        case .toggleInputMode(let toInputMode):
            guard state.reverseLookupSchema == nil else {
                changeSchema()
                return
            }
            
            if (state.mainSchema == .stroke || state.mainSchema.is10Keys) {
                clearInput()
            }
            
            state.inputMode = toInputMode
        case .toggleSymbolShape:
            switch state.symbolShape {
            case .full: state.symbolShapeOverride = .half
            case .half: state.symbolShapeOverride = .full
            default: ()
            }
        case .reverseLookup(let schema):
            state.reverseLookupSchema = schema
            changeSchema(shouldLeaveReverseLookupMode: false)
            return
        case .changeSchema(let schema):
            state.mainSchema = schema
            changeSchema()
            SessionState.main.lastPrimarySchema = schema
            return
        case .selectCandidate(let choice):
            candidateSelected(choice: choice, enableSmartSpace: true)
            candidateOrganizer.filterPrefix = nil
            hasMutatedComposition = true
        case .longPressCandidate(let choice):
            candidateLongPressed(choice: choice)
        case .exportFile(let namePrefix, let path):
            state.enableState = .loading
            keyboardViewController?.keyboardView?.state = state
            
            let zipFilePath = FileManager.default.temporaryDirectory.appendingPathComponent("\(namePrefix)-\(NSDate().timeIntervalSince1970).zip")
            DispatchQueue.global(qos: .userInteractive).async { [self] in
                do {
                    try FileManager.default.zipItem(at: URL(fileURLWithPath: path, isDirectory: true), to: zipFilePath)
                    let share = UIActivityViewController(activityItems: [zipFilePath], applicationActivities: nil)
                    DispatchQueue.main.async { keyboardViewController?.present(share, animated: true, completion: nil) }
                } catch {
                    DDLogError("Failed to export \(namePrefix) at \(path).")
                }
                DispatchQueue.main.async {
                    state.enableState = .enabled
                    keyboardViewController?.keyboardView?.state = state
                }
            }
        case .enableKeyboard(let e):
            state.enableState = e ? .enabled : .disabled
            keyboardViewController?.keyboardView?.state = state
        case .dismissKeyboard:
            keyboardViewController?.dismissKeyboard()
        case .resetComposition:
            compositionRenderer.textReset()
            needClearInput = true
            hasMutatedComposition = true
        case .setAutoSuggestion(let newAutoSuggestionType, let replaceTextLen):
            autoSuggestionTypeOverride = newAutoSuggestionType
            self.replaceTextLen = replaceTextLen
            updateInputState()
            return
        case .setFilter(let filterIndex):
            candidateOrganizer.filterPrefix = state.filters?[safe: filterIndex]
            candidateOrganizer.updateCandidates(reload: true)
            state.selectedFilterIndex = filterIndex
            return
        case .exit: exit(0)
        default: ()
        }
        autoSuggestionTypeOverride = nil
        if needClearInput {
            clearInput()
        } else {
            updateInputState()
        }
        if hasMutatedComposition {
            state.filters = []
            state.selectedFilterIndex = nil
            candidateOrganizer.filterPrefix = nil
        }
        updateComposition()
    }
    
    func refreshInputSettings() {
        if Settings.cached.isMixedModeEnabled && state.inputMode == .chinese { state.inputMode = .mixed }
        if !Settings.cached.isMixedModeEnabled && state.inputMode == .mixed { state.inputMode = .chinese }
        
        isImmediateMode = state.inputMode == .english || Settings.cached.compositionMode == .immediate
        if isImmediateMode {
            if !(compositionRenderer is ImmediateModeCompositionRenderer) {
                compositionRenderer = ImmediateModeCompositionRenderer(inputController: self)
            }
        } else {
            if !(compositionRenderer is MarkedTextCompositionRenderer) {
                compositionRenderer = MarkedTextCompositionRenderer(inputController: self)
            }
        }
        
        let activeSchema = state.activeSchema
        let is10Keys = activeSchema == .jyutping10keys && state.inputMode != .english
        keyboardViewController?.hasFilterBar = is10Keys && state.keyboardType != .emojis
        keyboardViewController?.hasCompositionView = !is10Keys && (isImmediateMode || activeSchema.isCangjieFamily && state.inputMode == .mixed)
        keyboardViewController?.hasCompositionResetButton = !is10Keys && isImmediateMode && state.isComposing
    }
    
    func isTextFieldWebSearch() -> Bool {
        guard let textFieldType = textDocumentProxy?.keyboardType else { return false }
        // DDLogInfo("isTextChromeSearchBar \(textFieldType) \(textDocumentProxy?.documentContextBeforeInput ?? "<empty-documentContextBeforeInput>")")
        // Finding: documentContextBeforeInput might not contain the full url.
        return textFieldType == UIKeyboardType.webSearch
    }
    
    private func shouldApplyAutoCap() -> Bool {
        guard let textDocumentProxy = textDocumentProxy else { return false }
        //print("autocapitalizationType", textDocumentProxy.autocapitalizationType?.rawValue)
        if textDocumentProxy.autocapitalizationType == .some(.none) ||
            inputEngine.isComposing ||
            isHoldingShift
            { return false }
        
        // There are three cases we should apply auto cap:
        // - First char in the doc. nil
        // - Half shaped: e.g. ". " -> "<sym><space>"
        // - Full shaped: e.g. "。" -> "<sym>"
        let documentContextBeforeInput = documentContextBeforeInput
        let lastChar = documentContextBeforeInput.last
        let lastSymbol = documentContextBeforeInput.last(where: { $0 != " " })
        // DDLogInfo("documentContextBeforeInput \(documentContextBeforeInput) \(lastChar)")
        let isFirstCharInDoc = lastChar == nil || lastChar == "\n"
        let isHalfShapedCase = (lastChar?.isWhitespace ?? false && lastSymbol?.isHalfShapeTerminalPunctuation ?? false)
        let isFullShapedCase = lastChar?.isFullShapeTerminalPunctuation ?? false
        return isFirstCharInDoc || isHalfShapedCase || isFullShapedCase
    }
    
    private func checkAutoCap() {
        guard Settings.cached.isAutoCapEnabled && !isHoldingShift && state.reverseLookupSchema == nil &&
                (state.keyboardType == .alphabetic(.lowercased) || state.keyboardType == .alphabetic(.uppercased))
            else { return }
        let originalKeyboardType = state.keyboardType
        state.keyboardType = shouldApplyAutoCap() ? .alphabetic(.uppercased) : .alphabetic(.lowercased)
        if originalKeyboardType != state.keyboardType {
            state.lastKeyboardTypeChangeFromAutoCap = true
        }
    }
    
    private func changeSchema(shouldLeaveReverseLookupMode: Bool = true) {
        inputEngine.rimeSchema = state.activeSchema
        if state.inputMode == .english {
            handleKey(.toggleInputMode(state.inputMode.afterToggle))
        }
        clearInput(shouldLeaveReverseLookupMode: shouldLeaveReverseLookupMode)
    }
    
    private func clearInput(shouldLeaveReverseLookupMode: Bool = true) {
        inputEngine.clearInput()
        if shouldLeaveReverseLookupMode {
            state.reverseLookupSchema = nil
            inputEngine.rimeSchema = state.activeSchema
        }
        replaceTextLen = 0
        updateInputState()
        updateComposition()
    }
    
    private func insertText(_ text: String, requestSmartSpace: Bool = false) {
        guard !text.isEmpty else { return }
        guard let textDocumentProxy = textDocumentProxy else { return }
        let isNewLine = text == "\n"
        
        if shouldRemoveSmartSpace(text) {
            compositionRenderer.removeCharBeforeInput()
            hasInsertedAutoSpace = false
        }
        
        var textToBeInserted: String
        
        if shouldInsertSmartSpace(text, requestSmartSpace, isNewLine) {
            textToBeInserted = text + " "
            hasInsertedAutoSpace = true
        } else {
            textToBeInserted = text
            hasInsertedAutoSpace = false
        }
        
        // After countless attempt, this provides the best compatibility.
        // Test cases:
        // Normal text fields
        // Safari/Chrome searching on www.youtube.com, enter should trigger search. Requires a special hack when inserting "\n".
        // Chrome address bar, entering the first character should clear out the current url.
        // GMail search field.
        // Google Calender create event title text field
        // Twitter search bar: enter 𥄫女 (𥄫 is a multiple codepoints char)
        // Slack
        // Number only text field, keyboard should be able to insert multiple digits.
        if compositionRenderer.hasText {
            // Calling setMarkedText("") & unmarkText() here won't work in Slack. It will insert the text twice.
            compositionRenderer.update(withCaretAtTheEnd: textToBeInserted)
            compositionRenderer.commit()
        } else {
            textDocumentProxy.insertText(textToBeInserted)
        }
        
        needClearInput = true
        // DDLogInfo("insertText() hasInsertedAutoSpace \(hasInsertedAutoSpace) isLastInsertedTextFromCandidate \(isLastInsertedTextFromCandidate)")
    }
    
    private func updateInputState() {
        guard state.isKeyboardAppearing else { return }
        
        updateContextualSuggestion()
        candidateOrganizer.updateCandidates(reload: needReloadCandidates)
        
        let isComposing = inputEngine.isComposing
        state.returnKeyType = isComposing && !isImmediateMode ? .confirm : ReturnKeyType(textDocumentProxy?.returnKeyType ?? .default)
        state.needsInputModeSwitchKey = keyboardViewController?.needsInputModeSwitchKey ?? false
        if !isComposing || state.inputMode == .english {
            state.spaceKeyMode = .space
        } else {
            let hasCandidate = isComposing && candidateOrganizer.getCandidateCount(section: 0) > 0
            switch Settings.cached.spaceAction {
            case .nextPage where hasCandidate: state.spaceKeyMode = .nextPage
            case .insertCandidate where hasCandidate: state.spaceKeyMode = .select
            default: state.spaceKeyMode = .space
            }
        }
        state.isComposing = isComposing
        
        updateSpaceState()
        
        keyboardViewController?.keyboardView?.state = state
    }
    
    private func updateSpaceState() {
        guard state.spaceKeyMode.isSpace else { return }
        
        guard state.inputMode != .english else {
            state.spaceKeyMode = .space
            return
        }

        let fullWidthSpaceMode = Settings.cached.fullWidthSpaceMode
        var isFullWidth: Bool
        switch fullWidthSpaceMode {
        case .off: isFullWidth = false
        case .shift:
            isFullWidth = state.keyboardType == .alphabetic(.uppercased) && !state.lastKeyboardTypeChangeFromAutoCap
        }
        
        state.spaceKeyMode = isFullWidth ? .fullWidthSpace : .space
    }
    
    private static func is10KeysSubKey(_ inputCode: Character, _ candidateCode: Character) -> Bool {
        switch candidateCode {
        case "a"..."c": return inputCode == "A"
        case "d"..."f": return inputCode == "D"
        case "g"..."i": return inputCode == "G"
        case "j"..."l": return inputCode == "J"
        case "m"..."o": return inputCode == "M"
        case "p"..."s": return inputCode == "P"
        case "t"..."v": return inputCode == "T"
        case "w"..."z": return inputCode == "W"
        default: return false
        }
    }
    
    private func update10KeysComposition() {
        let rimeRawInput = inputEngine.rimeRawInput?.text ?? ""
        guard !rimeRawInput.isEmpty,
              let rimeComposition = inputEngine.rimeComposition else {
            updateComposition(nil)
            return
        }
        let rimeCompositionText = inputEngine.rimeComposition?.text.filter({ $0 != " "}) ?? ""
        
        // Remaining input excluding selected text.
        let inputRemaining = rimeRawInput.commonSuffix(with: rimeCompositionText)
        
        let candidateCode = (inputEngine.getRimeCandidateComment(0) ?? "").filter { !$0.isNumber }
        
        var cIndex = candidateCode.startIndex
        var iIndex = inputRemaining.startIndex
        
        var morphedInput = ""
        // Scan the pending input string.
        while (iIndex < inputRemaining.endIndex) {
            let ic = inputRemaining[iIndex]
            
            // Ran out of candidate code. Just copy what's left in the input.
            if cIndex == candidateCode.endIndex {
                morphedInput.append(ic.lowercasedChar)
                iIndex = inputRemaining.index(after: iIndex)
                continue
            }
            
            let cc = candidateCode[cIndex]
            
            // NSLog("UFO iteration \(ic) \(cc)")
            if cc == " " {
                // If the candidate code is a space, append.
                if ic == "'" {
                    // Consume the "'" in input buffer
                    morphedInput.append("'")
                    iIndex = inputRemaining.index(after: iIndex)
                } else {
                    morphedInput.append(" ")
                }
                cIndex = candidateCode.index(after: cIndex)
            } else if ic == "'" {
                // Insert ' and skip to the code of the next candidate char
                morphedInput.append(ic)
                iIndex = inputRemaining.index(after: iIndex)
                
                while cIndex < candidateCode.endIndex && candidateCode[cIndex] != " " {
                    cIndex = candidateCode.index(after: cIndex)
                }
            } else {
                // Overwrite input char by the candidate code.
                if !Self.is10KeysSubKey(ic, cc) {
                    // If we encounter an input letter cannot be mapped to the current candidate letter,
                    // skip to next candidate char.
                    while cIndex < candidateCode.endIndex && candidateCode[cIndex] != " " {
                        cIndex = candidateCode.index(after: cIndex)
                    }
                    continue
                }
                morphedInput.append(cc)
                cIndex = candidateCode.index(after: cIndex)
                iIndex = inputRemaining.index(after: iIndex)
            }
        }
        
        let selectedInput = rimeCompositionText.prefix(rimeCompositionText.count - inputRemaining.count)
        //NSLog("UFO selectedInput \(selectedInput)")
        
        let composition = String(selectedInput + morphedInput)
        let inputCaretPosFromTheRight = rimeComposition.text.count - rimeComposition.caretIndex
        let caretPos = composition.count - inputCaretPosFromTheRight
        updateComposition(Composition(text: composition, caretIndex: caretPos))
        
        updateFilterBar(inputRemaining)
    }
    
    private func updateFilterBar(_ inputRemaining: String) {
        let prefixes = candidateOrganizer.candidateSource?.getCandidatePrefixes()
        var filterSet = Set<String>()
        let filters = prefixes?.compactMap { prefix -> String? in
            var iIndex = inputRemaining.startIndex
            var cIndex = prefix.startIndex
            
            var filter = ""
            while (iIndex < inputRemaining.endIndex && cIndex < prefix.endIndex) {
                let ic = inputRemaining[iIndex]
                let cc = prefix[cIndex]
                
                if Self.is10KeysSubKey(ic, cc) {
                    filter.append(cc)
                } else {
                    break
                }
                cIndex = prefix.index(after: cIndex)
                iIndex = inputRemaining.index(after: iIndex)
            }
            guard !filter.isEmpty && !filterSet.contains(filter) else { return nil }
            // NSLog("UFO \(inputRemaining) \(prefix) \(filter)")
            filterSet.insert(filter)
            return filter
        }
        candidateOrganizer.filterPrefix = nil
        state.filters = filters
        // DDLogInfo("UFO \(filters)")
    }
    
    private func updateComposition() {
        refreshInputSettings()

        if state.activeSchema.is10Keys && state.inputMode != .english {
            update10KeysComposition()
            return
        }
        
        switch state.inputMode {
        case .chinese: updateComposition(inputEngine.composition)
        case .english: updateComposition(inputEngine.englishComposition)
        case .mixed:
            if state.activeSchema.isCangjieFamily {
                // Show both Cangjie radicals and english composition in marked text.
                // let composition = inputEngine.rimeComposition
                // composition?.text += " " + (inputEngine.englishComposition?.text ?? "")
                // updateComposition(composition)
                updateComposition(inputEngine.englishComposition)
            } else {
                updateComposition(inputEngine.composition)
            }
        }
        
        if state.activeSchema.isCangjieFamily && state.inputMode != .english {
            keyboardViewController?.compositionLabelView?.composition = inputEngine.rimeComposition
        } else if state.inputMode == .english {
            keyboardViewController?.compositionLabelView?.composition = inputEngine.englishComposition
        } else {
            keyboardViewController?.compositionLabelView?.composition = inputEngine.composition
        }
    }
    
    private func updateComposition(_ composition: Composition?) {
        guard let textDocumentProxy = textDocumentProxy else { return }
        
        guard var text = composition?.text, !text.isEmpty else {
            compositionRenderer.clear()
            return
        }
        var caretPosition = composition?.caretIndex ?? NSNotFound
        
        let inputType = textDocumentProxy.keyboardType ?? .default
        let shouldStripSpace = inputType == .URL || inputType == .emailAddress || inputType == .webSearch || isImmediateMode
        if shouldStripSpace {
            let spaceStrippedSpace = text.filter { $0 != " " }
            caretPosition -= text.prefix(caretPosition).reduce(0, { $0 + ($1 != " " ? 0 : 1) })
            text = spaceStrippedSpace
        }
        
        compositionRenderer.update(text: text, caretIndex: text.index(text.startIndex, offsetBy: caretPosition))
    }
    
    private var shouldEnableSmartInput: Bool {
        guard let textFieldType = textDocumentProxy?.keyboardType else { return true }
        let isSmartEnglishSpaceEnabled = Settings.cached.isSmartEnglishSpaceEnabled || state.inputMode == .english
        return isSmartEnglishSpaceEnabled &&
            textFieldType != .URL &&
            textFieldType != .asciiCapableNumberPad &&
            textFieldType != .decimalPad &&
            textFieldType != .emailAddress &&
            textFieldType != .namePhonePad &&
            textFieldType != .numberPad &&
            textFieldType != .numbersAndPunctuation &&
            textFieldType != .phonePad;
    }
    
    private func insertComposingText(appendBy: String? = nil, shouldDisableSmartSpace: Bool = false) -> Bool {
        if let englishText = inputEngine.englishComposition?.text,
           var composingText = inputEngine.composition?.text.filter({ $0 != " " }),
           !composingText.isEmpty {
            if inputEngine.rimeSchema.is10Keys && state.inputMode != .english {
                let rimeCompositionText = inputEngine.rimeComposition?.text.filter({ $0 != " "}) ?? ""
                let rimeRawInput = inputEngine.rimeRawInput?.text ?? ""
                let inputRemaining = rimeRawInput.commonSuffix(with: rimeCompositionText)
                let selectedInput = rimeCompositionText.prefix(rimeCompositionText.count - inputRemaining.count)
                let bestCandidate = inputEngine.getRimeCandidate(0) ?? ""
                composingText = selectedInput + bestCandidate
            } else if state.inputMode == .english || state.inputMode == .mixed && composingText.first?.isEnglishLetter ?? false {
                composingText = englishText
            } else if inputEngine.rimeSchema.supportCantoneseTonalInput && Settings.cached.toneInputMode == .vxq {
                var englishTailLength = 0
                for c in composingText.reversed() {
                    switch c {
                    case "4", "5", "6": englishTailLength += 2
                    case c where !c.isASCII: break
                    default: englishTailLength += 1
                    }
                }
                let composingTextWithTonesReplaced = String(composingText.prefix(while: { !$0.isASCII }) + englishText.suffix(englishTailLength))
                composingText = composingTextWithTonesReplaced
            }
            EnglishInputEngine.userDictionary.learnWordIfNeeded(word: composingText)
            if let c = appendBy { composingText.append(c) }
            insertText(composingText, requestSmartSpace: !shouldDisableSmartSpace)
            return true
        }
        return false
    }
    
    private func moveCursor(offset: Int) {
        if inputEngine.isComposing {
            _ = inputEngine.moveCaret(offset: offset)
        } else {
            self.textDocumentProxy?.adjustTextPosition(byCharacterOffset: offset)
        }
    }
    
    private func handleAutoSpace() -> Bool {
        guard let textDocumentProxy = textDocumentProxy else { return false }
        
        // DDLogInfo("handleAutoSpace() hasInsertedAutoSpace \(hasInsertedAutoSpace) isLastInsertedTextFromCandidate \(isLastInsertedTextFromCandidate)")
        let last2CharsInDoc = documentContextBeforeInput.suffix(2)
        if hasInsertedAutoSpace, case .selectCandidate = lastKey {
            // Mimic iOS stock behaviour. Swallow the space tap.
            return true
        } else if (hasInsertedAutoSpace || lastKey?.isSpace ?? false) &&
           Settings.cached.isSmartFullStopEnabled &&
           (last2CharsInDoc.first ?? " ").couldBeFollowedBySmartSpace && last2CharsInDoc.last?.isWhitespace ?? false {
            // Translate double space tap into ". "
            textDocumentProxy.deleteBackward()
            if state.keyboardContextualType.halfWidthSymbol {
                textDocumentProxy.insertText(". ")
                hasInsertedAutoSpace = true
            } else {
                textDocumentProxy.insertText("。")
                hasInsertedAutoSpace = false
            }
            return true
        }
        return false
    }
    
    private func shouldRemoveSmartSpace(_ textBeingInserted: String) -> Bool {
        // If we are inserting newline in Google Chrome address bar, do not remove smart space
        guard !(isTextFieldWebSearch() && textBeingInserted == "\n") else { return false }
        
        let documentContextBeforeInput = documentContextBeforeInput
        let last2CharsInDoc = documentContextBeforeInput.suffix(2)
        
        // Always keep smart space if quotes or non punct symbols are being inserted
        if let firstChar = textBeingInserted.first,
           firstChar.isOpeningQuote || firstChar.isSymbol && !firstChar.isPunctuation {
            return false
        }
        
        if hasInsertedAutoSpace && last2CharsInDoc.last?.isWhitespace ?? false {
            // Remove leading smart space if:
            // English" "(中/.)
            if (last2CharsInDoc.first?.isEnglishLetterOrDigit ?? false) && !textBeingInserted.first!.isEnglishLetterOrDigit ||
                textBeingInserted == "\n" {
                // For some reason deleteBackward() does nothing unless it's wrapped in an main async block.
                // TODO Remove this.
                DDLogInfo("Should remove smart space. last2CharsInDoc '\(last2CharsInDoc)'")
                return true
            }
        }
        return false
    }
    
    private func shouldInsertSmartSpace(_ insertingText: String, _ isFromCandidateBar: Bool, _ isNewLine: Bool) -> Bool {
        guard shouldEnableSmartInput && !isNewLine,
              let lastChar = insertingText.last else { return false }
        
        // If we are typing a url or just sent combo text like .com, do not insert smart space.
        if case .url = state.keyboardContextualType, insertingText.contains(".") { return false }
        
        // If the user is typing something like a url, do not insert smart space.
        let documentContextBeforeInput = documentContextBeforeInput
        let lastSpaceIndex = documentContextBeforeInput.lastIndex(where: { $0.isWhitespace })
        let lastDotIndex = documentContextBeforeInput.lastIndex(of: ".")
        
        guard lastDotIndex == nil ||
              // Scan the text before input from the end, if we hit a dot before hitting a space, do not insert smart space.
              lastSpaceIndex != nil && documentContextBeforeInput.distance(from: lastDotIndex!, to: lastSpaceIndex!) >= 0 else {
            // DDLogInfo("Guessing user is typing url \(textDocumentProxy.documentContextBeforeInput)")
            return false
        }
        
        
        let nextChar = documentContextAfterInput.first
        // Insert space after english letters and [.,;], and if the input is followed by an English letter.
        // If the input isnt from the candidate bar and there are chars following, do not insert space.
        let isTextFromCandidateBarOrCommitingAtTheEnd = isFromCandidateBar && (nextChar == nil || nextChar?.isEnglishLetter ?? false)
        let isInsertingEnglishWordBeforeEnglish = lastChar.isEnglishLetter && (nextChar?.isEnglishLetter ?? true)
        return isTextFromCandidateBarOrCommitingAtTheEnd && isInsertingEnglishWordBeforeEnglish
    }
    
    private func refreshKeyboardContextualType() {
        guard let textDocumentProxy = textDocumentProxy else { return }
        let symbolShape = Settings.cached.symbolShape
        
        if textDocumentProxy.keyboardType == .URL || textDocumentProxy.keyboardType == .webSearch {
            state.keyboardContextualType = .url
            return
        } else {
            switch symbolShape {
            case .smart:
                switch state.inputMode {
                case .chinese: state.keyboardContextualType = .chinese
                case .english where !Settings.cached.isMixedModeEnabled: state.keyboardContextualType = .english
                default:
                    let isEnglish = isUserTypingEnglish(documentContextBeforeInput: documentContextBeforeInput)
                    state.keyboardContextualType = isEnglish ? .english : .chinese
                }
            case .half: state.keyboardContextualType = .english
            case .full: state.keyboardContextualType = .chinese
            }
            
            for specialSymbol in SpecialSymbol.allCases {
                let symbolShape = specialSymbol.determineSymbolShape(textBefore: documentContextBeforeInput)
                state.specialSymbolShapeOverride[specialSymbol] = symbolShape
            }
        }
        if inputEngine.isComposing {
            state.keyboardContextualType = .rime(languageContext: state.keyboardContextualType)
        }
    }
    
    private func isUserTypingEnglish(documentContextBeforeInput: String) -> Bool {
        var chineseCharCount = 0
        var englishWordCount = 0
        
        let lastChar = documentContextBeforeInput.last
        let text = (lastChar?.isTerminalPunctuation ?? false) ? documentContextBeforeInput.prefix(documentContextBeforeInput.count - 1) : documentContextBeforeInput[...]
        let lastSentenseStartIndex = text.lastIndex(where: { $0.isTerminalPunctuation }) ?? documentContextBeforeInput.startIndex
        let lastSentense = documentContextBeforeInput.suffix(from: lastSentenseStartIndex)
        var hasStartedEnglishWord = false
        for c in lastSentense {
            chineseCharCount += c.isChineseChar ? 1 : 0
            if c.isEnglishLetter {
                if !hasStartedEnglishWord {
                    hasStartedEnglishWord = true
                    englishWordCount += 1
                }
            } else {
                hasStartedEnglishWord = false
            }
        }
        
        if chineseCharCount > englishWordCount {
            return false
        } else if chineseCharCount < englishWordCount {
            return true
        } else {
            return Settings.cached.smartSymbolShapeDefault != .full
        }
    }
    
    private func showAutoSuggestCandidates() {
        let textBeforeInput = documentContextBeforeInput
        
        var newAutoSuggestionType: AutoSuggestionType?
        
        defer {
            candidateOrganizer.autoSuggestionType = newAutoSuggestionType
            candidateOrganizer.suggestionContextualText = textBeforeInput
        }
        
        guard let lastCharBefore = textBeforeInput.last else {
            return
        }
        
        if let autoSuggestionTypeOverride = autoSuggestionTypeOverride {
            newAutoSuggestionType = autoSuggestionTypeOverride
            return
        }
        
        switch lastCharBefore {
        case "@":
            newAutoSuggestionType = .email
            return
        case ".":
            newAutoSuggestionType = .domain
            return
        default: ()
        }
        
        switch state.keyboardContextualType {
        case .english: newAutoSuggestionType = .halfWidthPunctuation
        case .chinese: newAutoSuggestionType = .fullWidthPunctuation
        case .url: newAutoSuggestionType = .domain
        default: ()
        }
    }
}

extension InputController: KeyboardViewDelegate {
    func handleInputModeList(from: UIView, with: UIEvent) {
        keyboardViewController?.handleInputModeList(from: from, with: with)
    }
}
