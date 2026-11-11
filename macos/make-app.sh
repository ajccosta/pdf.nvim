#!/bin/sh
# make-app.sh [DIR]: build "pdf.nvim.app" in DIR (~/Applications), which opens
# each PDF it is given in nvim, in a new iTerm tab. To make it the default
# for PDFs: Finder, a PDF's Get Info, Open with: pdf.nvim, Change All.
set -e
dir=${1:-$HOME/Applications}
app=$dir/pdf.nvim.app
mkdir -p "$dir"
rm -rf "$app"
osacompile -o "$app" -e '
on open docs
	repeat with d in docs
		do shell script quoted form of POSIX path of (path to resource "open.sh") & " " & quoted form of POSIX path of d
	end repeat
end open'
# open.sh FILE: a script iTerm runs in a new window (no permission to control
# iTerm needed), through an interactive login shell for its PATH (nvim, python3)
cat > "$app/Contents/Resources/open.sh" <<'SH'
#!/bin/sh
f=$(mktemp -t pdf.nvim) && mv "$f" "$f.command" && f=$f.command
q=$(printf %s "$1" | sed "s/'/'\\\\''/g")
printf '%s\n' '#!/bin/zsh -il' 'rm -f -- "$0"' "exec nvim '$q'" > "$f"
chmod +x "$f"
open -a iTerm "$f"
SH
chmod +x "$app/Contents/Resources/open.sh"
plist=$app/Contents/Info.plist
pb() { /usr/libexec/PlistBuddy -c "$1" "$plist"; }
pb "Set :CFBundleIdentifier io.github.ajccosta.pdf-nvim" 2>/dev/null || pb "Add :CFBundleIdentifier string io.github.ajccosta.pdf-nvim"
pb "Delete :CFBundleDocumentTypes" 2>/dev/null || true
pb "Add :CFBundleDocumentTypes array"
pb "Add :CFBundleDocumentTypes:0 dict"
pb "Add :CFBundleDocumentTypes:0:CFBundleTypeName string PDF"
pb "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Editor"
pb "Add :CFBundleDocumentTypes:0:LSItemContentTypes array"
pb "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string com.adobe.pdf"
codesign --force --sign - "$app"  # again, after the changes above
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "made $app"
