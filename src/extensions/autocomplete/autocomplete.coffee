{View, $$} = require 'space-pen'
$ = require 'jquery'
_ = require 'underscore'
Range = require 'range'
Editor = require 'editor'
fuzzyFilter = require 'fuzzy-filter'

module.exports =
class Autocomplete extends View
  @content: ->
    @div class: 'autocomplete', tabindex: -1, =>
      @ol outlet: 'matchesList'
      @subview 'miniEditor', new Editor(mini: true)

  editor: null
  miniEditor: null
  currentBuffer: null
  wordList: null
  wordRegex: /\w+/g
  allMatches: null
  filteredMatches: null
  currentMatchIndex: null
  isAutocompleting: false
  originalSelectionBufferRange: null
  originalSelectedText: null

  @activate: (rootView) ->
    new Autocomplete(editor) for editor in rootView.getEditors()
    rootView.on 'editor-open', (e, editor) ->
      new Autocomplete(editor) unless editor.is('.autocomplete .mini')

  initialize: (@editor) ->
    requireStylesheet 'autocomplete.css'
    @handleEvents()
    @setCurrentBuffer(@editor.getBuffer())

  handleEvents: ->
    @editor.on 'editor-path-change', => @setCurrentBuffer(@editor.getBuffer())
    @editor.on 'before-remove', => @currentBuffer?.off '.autocomplete'

    @editor.on 'autocomplete:attach', => @attach()
    @editor.on 'autocomplete:cancel', => @cancel()
    @on 'autocomplete:confirm', => @confirm()

    @matchesList.on 'mousedown', (e) =>
      index = $(e.target).attr('index')
      @selectMatchAtIndex(index) if index?
      false

    @matchesList.on 'mouseup', =>
      if @selectedMatch()
        @confirm()
      else
        @cancel()

    @miniEditor.getBuffer().on 'change', (e) =>
      @filterMatches() if @hasParent()

    @miniEditor.preempt 'move-up', =>
      @selectPreviousMatch()
      false

    @miniEditor.preempt 'move-down', =>
      @selectNextMatch()
      false

    @miniEditor.preempt 'textInput', (e) =>
      text = e.originalEvent.data
      unless text.match(@wordRegex)
        @confirm()
        @editor.insertText(text)
        false

  setCurrentBuffer: (buffer) ->
    @currentBuffer?.off '.autocomplete'
    @currentBuffer = buffer
    @buildWordList()
    @currentBuffer.on 'change.autocomplete', (e) =>
      @buildWordList() unless @isAutocompleting

  buildWordList: () ->
    wordHash = {}
    matches = @currentBuffer.getText().match(@wordRegex)
    wordHash[word] ?= true for word in (matches or [])

    @wordList = Object.keys(wordHash)

  confirm: ->
    @confirmed = true
    @editor.getSelection().clear()
    @detach()
    return unless match = @selectedMatch()
    position = @editor.getCursorBufferPosition()
    @editor.setCursorBufferPosition([position.row, position.column + match.suffix.length])

  cancel: ->
    @detach()
    @editor.getBuffer().change(@currentMatchBufferRange, @originalSelectedText) if @currentMatchBufferRange
    @editor.setSelectedBufferRange(@originalSelectionBufferRange)

  attach: ->
    @confirmed = false
    @miniEditor.on 'focusout', =>
      @cancel() unless @confirmed

    @originalSelectedText = @editor.getSelectedText()
    @originalSelectionBufferRange = @editor.getSelection().getBufferRange()
    @currentMatchBufferRange = null
    @allMatches = @findMatchesForCurrentSelection()

    originalCursorPosition = @editor.getCursorScreenPosition()
    @filterMatches()
    @editor.append(this)
    @setPosition(originalCursorPosition)

    @miniEditor.focus()

  detach: ->
    @miniEditor.off("focusout")
    super
    @editor.off(".autocomplete")
    @editor.focus()
    @miniEditor.setText('')

  setPosition: (originalCursorPosition) ->
    { left, top } = @editor.pixelPositionForScreenPosition(originalCursorPosition)

    top -= @editor.scrollTop()
    potentialTop = top + @editor.lineHeight
    potentialBottom = potentialTop + @outerHeight()

    if potentialBottom > @editor.outerHeight()
      @css(left: left, bottom: @editor.outerHeight() - top, top: 'inherit')
    else
      @css(left: left, top: potentialTop, bottom: 'inherit')

  selectPreviousMatch: ->
    previousIndex = @currentMatchIndex - 1
    previousIndex = @filteredMatches.length - 1 if previousIndex < 0
    @selectMatchAtIndex(previousIndex)

  selectNextMatch: ->
    nextIndex = (@currentMatchIndex + 1) % @filteredMatches.length
    @selectMatchAtIndex(nextIndex)

  selectMatchAtIndex: (index) ->
    @currentMatchIndex = index
    @matchesList.find("li").removeClass "selected"

    liToSelect = @matchesList.find("li:eq(#{index})")
    liToSelect.addClass "selected"

    topOfLiToSelect = liToSelect.position().top + @matchesList.scrollTop()
    bottomOfLiToSelect = topOfLiToSelect + liToSelect.outerHeight()
    if topOfLiToSelect < @matchesList.scrollTop()
      @matchesList.scrollTop(topOfLiToSelect)
    else if bottomOfLiToSelect > @matchesList.scrollBottom()
      @matchesList.scrollBottom(bottomOfLiToSelect)

    @replaceSelectedTextWithMatch @selectedMatch()

  selectedMatch: ->
    @filteredMatches[@currentMatchIndex]

  filterMatches: ->
    @filteredMatches = fuzzyFilter(@allMatches, @miniEditor.getText(), key: 'word')
    @renderMatchList()

  renderMatchList: ->
    @matchesList.empty()
    if @filteredMatches.length > 0
      @matchesList.append($$ -> @li match.word, index: index) for match, index in @filteredMatches
    else
      @matchesList.append($$ -> @li "No matches found")

    @selectMatchAtIndex(0) if @filteredMatches.length > 0

  findMatchesForCurrentSelection: ->
    selection = @editor.getSelection()
    {prefix, suffix} = @prefixAndSuffixOfSelection(selection)

    if (prefix.length + suffix.length) > 0
      regex = new RegExp("^#{prefix}(.+)#{suffix}$", "i")
      currentWord = prefix + @editor.getSelectedText() + suffix
      for word in @wordList when regex.test(word) and word != currentWord
        match = regex.exec(word)
        {prefix, suffix, word, infix: match[1]}
    else
      []

  replaceSelectedTextWithMatch: (match) ->
    selection = @editor.getSelection()
    startPosition = selection.getBufferRange().start
    @isAutocompleting = true
    @editor.insertText(match.infix)

    @currentMatchBufferRange = [startPosition, [startPosition.row, startPosition.column + match.infix.length]]
    @editor.setSelectedBufferRange(@currentMatchBufferRange)
    @isAutocompleting = false

  prefixAndSuffixOfSelection: (selection) ->
    selectionRange = selection.getBufferRange()
    lineRange = [[selectionRange.start.row, 0], [selectionRange.end.row, @editor.lineLengthForBufferRow(selectionRange.end.row)]]
    [prefix, suffix] = ["", ""]

    @currentBuffer.scanInRange @wordRegex, lineRange, (match, range, {stop}) ->
      stop() if range.start.isGreaterThan(selectionRange.end)

      if range.intersectsWith(selectionRange)
        prefixOffset = selectionRange.start.column - range.start.column
        suffixOffset = selectionRange.end.column - range.end.column

        prefix = match[0][0...prefixOffset] if range.start.isLessThan(selectionRange.start)
        suffix = match[0][suffixOffset..] if range.end.isGreaterThan(selectionRange.end)

    {prefix, suffix}
