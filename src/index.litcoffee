Node-XLSX-Writer
================

Node-XLSX-Writer is written in literate coffeescript. The following is the actual source of the 
module.

    fs = require('fs')
    Zip = require('node-zip')
    blobs = require('./blobs')

    module.exports = class XlsxWriter


### Simple writes

##### XlsxWriter.write(out: String, data: Array, cb: Function)

The simplest way to use Node-XLSX-Writer is to use the write method.

The callback comes directly from `fs.writeFile` and has the arity `(err)`

      # @param {String} out Output file path.
      # @param {Array} data Data to write.
      # @param {Function} cb Callback to call when done. Fed (err).
      @write = (out, data, cb) ->
          writer = new XlsxWriter(out)
          writer.addRows(data)
          writer.writeToFile(cb)

### Advanced usage

Node-XLSX-Writer has more advanced features available for better customization
of spreadsheets.

When constructing a writer, pass it an optional file path and customization options.

##### new XlsxWriter([out]: String, [options]: Object) : XlsxWriter

      # Build a writer object.
      # @param {String} [out] Destination file path.
      # @param {Object} [options] Preparation options.
      constructor: (out = '', options = {}) ->
          # Allow passing options only.
          if (typeof out != 'string')
              options = out
              out = ''

          # Assign output path.
          @out = out

          # Set options.
          defaults = {
              defaultWidth: 15
          }
          @options = _extend(defaults, options)

          @_resetSheet()


#### Adding rows

Rows are easy to add one by one or all at once. Data types within the sheet will 
be inferred from the data types passed to addRow().

##### addRow(row: Object)

Add a single row.

      # @example (javascript)
      # writer.addRow({
      #     "A String Column" : "A String Value",
      #     "A Number Column" : 12345,
      #     "A Date Column" : new Date(1999,11,31)
      # })
      addRow: (row) ->

        # Values in header are defined by the keys of the object we've passed in.
        # They need to be written the first time they're passed in.
        if !@haveHeader
          @_write(blobs.sheetDataHeader)
          @_startRow()
          col = 1
          for key of row
            @_addCell(key, col)
            @cellMap.push(key)
            col += 1
          @_endRow()

          @haveHeader = true

        @_startRow()
        for key, col in @cellMap
          @_addCell(row[key] || "", col + 1)
        @_endRow()

##### addRows(rows: Array)

Rows can be added in batch.

      addRows: (rows) ->
        for row in rows
          @addRow(row)

##### defineColumns(columns: Array)

Column definitions can be easily added.

      # @example (javascript)
      # writer.defineColumns([
      #     {  width: 30 }, // width is in 'characters'
      #     {  width: 10 }
      # ])
      defineColumns: (@columns) ->

#### File generation

Once you are done adding rows & defining columns, you have a few options
for generating the file. The `writeToFile` helper is a one-stop-shop for writing
directly to a file using `fs.writeFile`; otherwise, you can pack() manually,
which will return a `Buffer` with the packed file.

##### writeToFile([fileName]: String, cb: Function)

Writes data to a file - split out from packing so we can use the raw buffer.

If no filename is specified, will attempt to use the one specified in the
constructor.

The callback is fed directly to `fs.writeFile`.

      # @param {String} [fileName] File path to write.
      # @param {Function} cb Callback.
      writeToFile: (fileName, cb) ->
        if fileName instanceof Function
          cb = fileName
          fileName = @out
        if !fileName
          return new Error("Filename required.")

        results = @zipContents or @pack()

        # Write to output location
        fs.writeFile(fileName, results, 'binary', cb)

##### pack([jsZipOptions]: Object) : Buffer

Packs the file and returns a raw buffer.

Will finalize the sheet & generate shared strings if they haven't been already. 

You may pass [JSZip options](http://stuk.github.io/jszip/#doc_generate_options) directly
to this method. Pass `{compression: 'STORE'}` for about 5x faster packing at the expense of file
size. In my tests, a 200x200 random data spreadsheet was 549KB with default settings and 
2.1MB with `{compression: 'STORE'}`.

If you are generating a large number of files or expect heavy request traffic, this could 
be a bottleneck and plug up the event loop. In that case, consider 
[threads](https://github.com/audreyt/node-webworker-threads).

      # @return {Buffer} Raw ZIP data.
      pack: (jsZipOptions = {}) ->
        # Create Zip (JSZip port, no native deps)
        zipFile = new Zip()

        # Add static supporting files
        zipFile.file('[Content_Types].xml', blobs.contentTypes)
        zipFile.file('_rels/.rels', blobs.rels)
        zipFile.file('xl/workbook.xml', blobs.workbook)
        zipFile.file('xl/styles.xml', blobs.styles)
        zipFile.file('xl/_rels/workbook.xml.rels', blobs.workbookRels)

        # Add sheet
        if (!@finalized)
          @finalize()
        zipFile.file('xl/worksheets/sheet1.xml', @sheetData)
        zipFile.file('xl/sharedStrings.xml', @stringsData)

        # Pack it up
        results = zipFile.generate(_extend({
          compression: 'DEFLATE',
          type: 'nodebuffer'
        }, jsZipOptions))

        @zipContents = results

        return results

##### finalize()

Finishes up the sheet & generate shared strings.

      finalize: () ->

        # If there was data, end sheetData
        if @haveHeader
          @_write(blobs.sheetDataFooter)

        # Write column metadata
        @_write(@_generateColumnDefinition())

        # Write dimensions
        colCount = Object.keys(@cellLabelMap).length
        @_write(blobs.dimensions(@_getDimensionsData(@currentRow, colCount)))

        # End sheet
        @_write(blobs.sheetFooter)

        # Generate shared strings
        @_generateStrings()

        # Mark this as finished
        @finalized = true


#### Internal methods


Adds a cell to the row in progress.

      # @param {String|Number|Date} value Value to write.
      # @param {Number}             col   Column index.
      _addCell: (value = '', col) ->
        row = @currentRow
        cell = @_getCellIdentifier(row, col)

        if typeof value == 'number'
          @rowBuffer += blobs.numberCell(value, cell)
        else if value instanceof Date
          date = @_dateToOADate(value)
          @rowBuffer += blobs.dateCell(date, cell)
        else
          index = @_lookupString(value)
          @rowBuffer += blobs.cell(index, cell)

Begins a row. Call this before starting any row. Will start a buffer
for all proceeding cells, until @_endRow is called.

      _startRow: () ->
        @rowBuffer = blobs.startRow(@currentRow)
        @currentRow += 1

Ends a row. Will write the row to the sheet.

      _endRow: () ->
        @_write(@rowBuffer + blobs.endRow)

Internal generator for writing dimension data to the sheet.

      # @param {Number} rows Row count.
      # @param {Number} cols Column count.
      # @return {String}     SpreadsheetML dimension data.
      _getDimensionsData: (rows, columns) ->
        return "A1:" + @_getCellIdentifier(rows, columns)

Given row and column indices, returns a cell identifier, e.g. "E20"

      # @param {Number} row  Row index.
      # @param {Number} cell Cell index.
      # @return {String}     Cell identifier.
      _getCellIdentifier: (row, col) ->
        colIndex = ''
        if @cellLabelMap[col]
          colIndex = @cellLabelMap[col]
        else
          if col == 0
            # Provide a fallback for empty spreadsheets
            row = 1
            col = 1

          input = (+col - 1).toString(26)
          while input.length
            a = input.charCodeAt(input.length - 1)
            colIndex = String.fromCharCode(a + if a >= 48 and a <= 57 then 17 else -22) + colIndex
            input = if input.length > 1 then (parseInt(input.substr(0, input.length - 1), 26) - 1).toString(26) else ""
          @cellLabelMap[col] = colIndex

        return colIndex + row

Creates column definitions, if any definitions exist.
This will write column styles, widths, etc.

      # @return {String} Column definition.
      _generateColumnDefinition: () ->
        columnDefinition = ''
        columnDefinition += blobs.startColumns

        idx = 1
        for index, column of @columns
          columnDefinition += blobs.column(column.width || @options.defaultWidth, idx)
          idx += 1

        columnDefinition += blobs.endColumns
        return columnDefinition

Generates StringMap XML. Used as a finalization step - don't call this while
building the xlsx is in progress.

Saves string data to this object so it can be written by `pack()`.

      _generateStrings: () ->
        stringTable = ''
        for string in @strings
          stringTable += blobs.string(@escapeXml(string))
        @stringsData = blobs.stringsHeader(@strings.length) + stringTable + blobs.stringsFooter

Looks up a string inside the internal string map. If it doesn't exist, it will be added to the map.

      # @param {String} value String to look up.
      # @return {Number}      Index within the string map where this string is located.
      _lookupString: (value) ->
        if !@stringMap[value]
          @stringMap[value] = @stringIndex
          @strings.push(value)
          @stringIndex += 1
        return @stringMap[value]

Converts a Date to an OADate.
See [this stackoverflow post](http://stackoverflow.com/a/15550284/2644351)

      # @param {Date} date Date to convert.
      # @return {Number}   OADate.
      _dateToOADate: (date) ->
        epoch = new Date(1899,11,30)
        msPerDay = 8.64e7

        v = -1 * (epoch - date) / msPerDay;

        # Deal with dates prior to 1899-12-30 00:00:00
        dec = v - Math.floor(v)

        if v < 0 and dec
          v = Math.floor(v) - dec

        return v

Convert an OADate to a Date.

      # @param {Number} oaDate OADate.
      # @return {Date}         Converted date.
      _OADateToDate: (oaDate) ->
        epoch = new Date(1899,11,30)
        msPerDay = 8.64e7

        # Deal with -ve values
        dec = oaDate - Math.floor(oaDate)

        if oaDate < 0 and dec
          oaDate = Math.floor(oaDate) - dec

        return new Date(oaDate * msPerDay + +epoch)

Resets sheet data. Called on initialization.

      _resetSheet: () ->

        # Sheet data storage.
        @sheetData = ''
        @strings = []
        @stringMap = {}
        @stringIndex = 0
        @stringData = null
        @currentRow = 0

        # Cell data storage
        @cellMap = []
        @cellLabelMap = {}

        # Column data storage
        @columns = []

        # Flags
        @haveHeader = false
        @finalized = false

        # Start off the sheet.
        @_write(blobs.sheetHeader)

Wrapper around writing sheet data.

      # @param {String} data Data to write to the sheet.
      _write: (data) ->
        @sheetData += (data)

Utility method for escaping XML - used within blobs and can be used manually.

      # @param {String} str String to escape.
      escapeXml: (str = '') ->
        return str.replace(/&/g, '&amp;')
          .replace(/</g, '&lt;')
          .replace(/>/g, '&gt;')



Simple extend helper.

    _extend = (dest, src) ->
      for key, val of src
        dest[key] = val
      dest 