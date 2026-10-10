using terms from application "CotEditor"
    on document saved theDocument
        tell application "CotEditor"
            if coloring style of theDocument is not "Surge" then return
            set documentFile to get file of theDocument
        end tell
        set documentPath to POSIX path of documentFile
        try
            set reportText to do shell script (quoted form of (my checkerPath) & " --saved " & quoted form of documentPath & " 2>&1")
        on error errorText
            set reportText to errorText
        end try
        tell application "CotEditor" to write to console reportText
    end document saved
end using terms from

on run
    tell application "CotEditor" to write to console "Surge checks run after saving a document whose syntax is Surge. Use Check Surge to check unsaved edits."
end run
