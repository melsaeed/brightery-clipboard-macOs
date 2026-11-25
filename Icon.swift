import AppKit
let size = NSSize(width:1024,height:1024)
let img = NSImage(size:size, flipped:false) { rect in
    let bg = NSBezierPath(roundedRect:NSRect(x:72,y:72,width:880,height:880),xRadius:205,yRadius:205)
    NSGradient(starting:NSColor(srgbRed:0.35,green:0.25,blue:0.82,alpha:1),ending:NSColor(srgbRed:0.15,green:0.11,blue:0.46,alpha:1))?.draw(in:bg,angle: -75)
    let board = NSBezierPath(roundedRect:NSRect(x:290,y:240,width:444,height:530),xRadius:55,yRadius:55)
    NSColor.white.withAlphaComponent(0.98).setStroke(); board.lineWidth = 38; board.stroke()
    let top = NSBezierPath(roundedRect:NSRect(x:406,y:706,width:212,height:100),xRadius:38,yRadius:38); NSColor.white.setFill(); top.fill()
    for (y,w) in [(590.0,230.0),(490.0,230.0),(390.0,155.0)] {
        let line = NSBezierPath(roundedRect:NSRect(x:385,y:y,width:w,height:26),xRadius:13,yRadius:13); NSColor.white.withAlphaComponent(0.87).setFill(); line.fill()
    }
    return true
}
let bitmap = NSBitmapImageRep(data:img.tiffRepresentation!)!
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
