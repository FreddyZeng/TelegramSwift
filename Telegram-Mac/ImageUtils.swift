//
//  ImageUtils.swift
//  TelegramMac
//
//  Created by keepcoder on 18/01/2017.
//  Copyright © 2017 Telegram. All rights reserved.
//

import Cocoa
import Postbox
import TelegramCore
import FastBlur
import SwiftSignalKit
import TGUIKit
import FastBlur



final class PeerNameColorCache {
    
    struct Key : Hashable {
        let color: NSColor
        let dash: NSColor?
        let flipped: Bool
    }
    
    
    static let value: PeerNameColorCache = PeerNameColorCache()
    private var colors: [Key : NSColor] = [:]
    private init() {
        for color in PeerNameColor.allCases {
            cache(color.dashColors, flipped: false)
            cache(color.dashColors, flipped: true)
        }
    }
    
    @discardableResult private func cache(_ color: (NSColor, NSColor?), flipped: Bool = false) -> NSColor {
        if let _ = color.1 {
            let image = chatReplyLineDashTemplateImage(color, flipped: flipped)!
            let pattern = NSColor(patternImage: NSImage(cgImage: image, size: image.backingSize))
            colors[Key(color: color.0, dash: color.1, flipped: flipped)] = pattern
            return pattern
        } else {
            colors[.init(color: color.0, dash: nil, flipped: flipped)] = color.0
            return color.0
        }
    }
    
    func get(_ color:(NSColor, NSColor?), flipped: Bool = false) -> NSColor {
        let found = self.colors[.init(color: color.0, dash: color.1, flipped: flipped)]
        if let found = found {
            return found
        } else {
            return cache(color, flipped: flipped)
        }
    }
    
}



public extension PeerNameColor {
    var color: NSColor {
        return self.dashColors.0
    }
    
    var index: Int {
        switch self {
        case .red, .redDash:
            return 0
        case .orange,.orangeDash:
            return 1
        case .violet,.violetDash:
            return 2
        case .green, .greenDash:
            return 3
        case .cyan, .cyanDash:
            return 4
        case .blue, .blueDash:
            return 5
        case .pink, .pinkDash:
            return 6
        }
    }
    
    
    var dashColors: (NSColor, NSColor?) {
        switch self {
        case .red:
            return (NSColor(rgb: 0xCC5049), nil)
        case .orange:
            return (NSColor(rgb: 0xD67722), nil)
        case .violet:
            return (NSColor(rgb: 0x955CDB), nil)
        case .green:
            return (NSColor(rgb: 0x40A920), nil)
        case .cyan:
            return (NSColor(rgb: 0x309EBA), nil)
        case .blue:
            return (NSColor(rgb: 0x368AD1), nil)
        case .pink:
            return (NSColor(rgb: 0xC7508B), nil)
        case .redDash:
            return (NSColor(rgb: 0xE15052), NSColor(rgb: 0xF9AE63))
        case .orangeDash:
            return (NSColor(rgb: 0xE0802B), NSColor(rgb: 0xFAC534))
        case .violetDash:
            return (NSColor(rgb: 0xA05FF3), NSColor(rgb: 0xF48FFF))
        case .greenDash:
            return (NSColor(rgb: 0x27A910), NSColor(rgb: 0xA7DC57))
        case .cyanDash:
            return (NSColor(rgb: 0x27ACCE), NSColor(rgb: 0x82E8D6))
        case .blueDash:
            return (NSColor(rgb: 0x3391D4), NSColor(rgb: 0x7DD3F0))
        case .pinkDash:
            return (NSColor(rgb: 0xdd4371), NSColor(rgb: 0xffbe9f))
        }
    }
    
    var isDashed: Bool {
        return self.dashColors.1 != nil
    }
    
    var quoteIcon: CGImage {
        switch self {
        case .red:
            return theme.icons.message_quote_red
        case .orange:
            return theme.icons.message_quote_orange
        case .violet:
            return theme.icons.message_quote_violet
        case .green:
            return theme.icons.message_quote_green
        case .cyan:
            return theme.icons.message_quote_cyan
        case .blue:
            return theme.icons.message_quote_blue
        case .pink:
            return theme.icons.message_quote_pink
        case .redDash:
            return theme.icons.message_quote_red
        case .orangeDash:
            return theme.icons.message_quote_orange
        case .violetDash:
            return theme.icons.message_quote_violet
        case .greenDash:
            return theme.icons.message_quote_green
        case .cyanDash:
            return theme.icons.message_quote_cyan
        case .blueDash:
            return theme.icons.message_quote_blue
        case .pinkDash:
            return theme.icons.message_quote_pink
        }
    }
}


let graphicsThreadPool = ThreadPool(threadCount: 5, threadPriority: 1)

enum PeerPhoto {
    case peer(Peer, TelegramMediaImageRepresentation?, PeerNameColor?, [String], Message?)
    case topic(EngineMessageHistoryThread.Info, Bool)
}

private let capHolder:Atomic<[String : CGImage]> = Atomic(value: [:])

private func peerImage(account: Account, peer: Peer, displayDimensions: NSSize, representation: TelegramMediaImageRepresentation?, message: Message? = nil, displayLetters: [String], font: NSFont, scale: CGFloat, genCap: Bool, synchronousLoad: Bool, disableForum: Bool = false) -> Signal<(CGImage?, Bool), NoError> {
    
    let isForum: Bool = peer.isForum && !disableForum
    
    if let representation = representation {
        return cachedPeerPhoto(peer.id, representation: representation, peerNameColor: nil, size: displayDimensions, scale: scale, isForum: isForum) |> mapToSignal { cached -> Signal<(CGImage?, Bool), NoError> in
            return autoreleasepool {
                if let cached = cached {
                    return cachePeerPhoto(image: cached, peerId: peer.id, representation: representation, peerNameColor: nil, size: displayDimensions, scale: scale, isForum: isForum) |> map {
                        return (cached, false)
                    }
                } else {
                    let resourceData = account.postbox.mediaBox.resourceData(representation.resource, attemptSynchronously: synchronousLoad)
                    let imageData = resourceData
                        |> take(1)
                        |> mapToSignal { maybeData -> Signal<(Data?, Bool, Bool), NoError> in
                            return autoreleasepool {
                               if maybeData.complete {
                                   return .single((try? Data(contentsOf: URL(fileURLWithPath: maybeData.path)), false, false))
                               } else {
                                   return Signal { subscriber in
                                                
                                       if let data = representation.immediateThumbnailData {
                                           subscriber.putNext((decodeTinyThumbnail(data: data), false, true))
                                       }
                                    
                                       let resourceData = account.postbox.mediaBox.resourceData(representation.resource, attemptSynchronously: synchronousLoad)
                                    
                                       let resourceDataDisposable = resourceData.start(next: { data in
                                           if data.complete {
                                               subscriber.putNext((try? Data(contentsOf: URL(fileURLWithPath: data.path)), true, false))
                                               subscriber.putCompletion()
                                           } 
                                       }, completed: {
                                           subscriber.putCompletion()
                                       })
                                       
                                       let fetchedDataDisposable: Disposable
                                       if let message = message, message.author?.id == peer.id {
                                           fetchedDataDisposable = fetchedMediaResource(mediaBox: account.postbox.mediaBox, userLocation: .peer(peer.id), userContentType: .avatar, reference: MediaResourceReference.messageAuthorAvatar(message: MessageReference(message), resource: representation.resource), statsCategory: .image).start()
                                        } else if let reference = PeerReference(peer) {
                                            fetchedDataDisposable = fetchedMediaResource(mediaBox: account.postbox.mediaBox, userLocation: .peer(peer.id), userContentType: .avatar, reference: MediaResourceReference.avatar(peer: reference, resource: representation.resource), statsCategory: .image).start()
                                       } else {
                                           fetchedDataDisposable = fetchedMediaResource(mediaBox: account.postbox.mediaBox, userLocation: .peer(peer.id), userContentType: .avatar, reference: MediaResourceReference.standalone(resource: representation.resource), statsCategory: .image).start()
                                       }
                                       return ActionDisposable {
                                           resourceDataDisposable.dispose()
                                           fetchedDataDisposable.dispose()
                                       }
                                   }
                               }
                            }
                    }
                    
                    let def = deferred({ () -> Signal<(CGImage?, Bool), NoError> in
                        let key = NSStringFromSize(displayDimensions)
                        if let image = capHolder.with({ $0[key] }) {
                            return .single((image, false))
                        } else {
                            let size = NSMakeSize(max(15, displayDimensions.width), max(15, displayDimensions.height))
                            let image = generateAvatarPlaceholder(foregroundColor: theme.colors.grayBackground, size: size, cornerRadius: isForum ? floor(size.height / 3) : -1)
                            _ = capHolder.modify { current in
                                var current = current
                                current[key] = image
                                return current
                            }
                            return .single((image, false))
                        }
                    }) |> deliverOnMainQueue
                    
                    let loadDataSignal = synchronousLoad ? imageData : imageData |> deliverOn(graphicsThreadPool)
                    
                    let img = loadDataSignal |> mapToSignal { data, animated, tiny -> Signal<(CGImage?, Bool), NoError> in
                            
                        var image:CGImage?
                        if let data = data {
                            image = roundImage(data, displayDimensions, cornerRadius: isForum ? displayDimensions.width / 3 : -1, scale: scale)
                        } else {
                            image = nil
                        }
                        #if !SHARE
                        if tiny, let img = image {
                            let size = img.size
                            let ctx = DrawingContext(size: img.size, scale: 1.0)
                            ctx.withContext { ctx in
                                ctx.clear(size.bounds)
                                ctx.draw(img, in: size.bounds)
                            }
                            telegramFastBlurMore(Int32(size.width), Int32(size.height), Int32(ctx.bytesPerRow), ctx.bytes)
                            
                            let rounded = DrawingContext(size: img.size, scale: 1.0)
                            rounded.withContext { c in
                                c.clear(size.bounds)
                                c.round(size, isForum ? min(floor(size.height / 3), size.height / 2) : size.height / 2)
                                c.clear(size.bounds)
                                c.draw(ctx.generateImage()!, in: size.bounds)
                            }
                            
                            image = rounded.generateImage()//ctx.generateImage()
                        }
                        #endif
                        if let image = image {
                            if tiny {
                                return .single((image, animated))
                            }
                            return cachePeerPhoto(image: image, peerId: peer.id, representation: representation, peerNameColor: nil, size: displayDimensions, scale: scale, isForum: isForum) |> map {
                                return (image, animated)
                            }
                        } else {
                            return .single((image, animated))
                        }
                            
                    }
                    if genCap {
                        return def |> then(img)
                    } else {
                        return img
                    }
                }
            }
        }
        
    } else {
        
        var letters = displayLetters
        if letters.count < 2 {
            while letters.count != 2 {
                letters.append("")
            }
        }
        
        let index = peer.nameColor?.index ?? Int(abs(peer.id.id._internalGetInt64Value() % 7))
        let color = theme.colors.peerColors(index)

        
        let symbol = letters.reduce("", { (current, letter) -> String in
            return current + letter
        })
        
        return cachedEmptyPeerPhoto(peer.id, symbol: symbol, color: color.top, size: displayDimensions, scale: scale, isForum: isForum) |> mapToSignal { cached -> Signal<(CGImage?, Bool), NoError> in
            if let cached = cached {
                return .single((cached, false))
            } else {
                return generateEmptyPhoto(displayDimensions, type: .peer(colors: color, letter: letters, font: font, cornerRadius: isForum ? floor(displayDimensions.height / 3) : nil)) |> runOn(graphicsThreadPool) |> mapToSignal { image -> Signal<(CGImage?, Bool), NoError> in
                    if let image = image {
                        return cacheEmptyPeerPhoto(image: image, peerId: peer.id, symbol: symbol, color: color.top, size: displayDimensions, scale: scale, isForum: isForum) |> map {
                            return (image, false)
                        }
                    } else {
                        return .single((image, false))
                    }
                }
            }
        }
        
    }
}

func peerAvatarImage(account: Account, photo: PeerPhoto, displayDimensions: CGSize = CGSize(width: 60.0, height: 60.0), scale:CGFloat = 1.0, font:NSFont = .medium(17), genCap: Bool = true, synchronousLoad: Bool = false, disableForum: Bool = false) -> Signal<(CGImage?, Bool), NoError> {
   
    switch photo {
    case let .peer(peer, representation, peerNameColor, displayLetters, message):
        return peerImage(account: account, peer: peer, displayDimensions: displayDimensions, representation: representation, message: message, displayLetters: displayLetters, font: font, scale: scale, genCap: genCap, synchronousLoad: synchronousLoad, disableForum: disableForum)
    case let .topic(info, isGeneral):
        #if !SHARE
      
        let file: Signal<TelegramMediaFile, NoError>
        
        if let fileId = info.icon {
            file = TelegramEngine(account: account).stickers.resolveInlineStickers(fileIds: [fileId]) |> map {
                return $0[fileId]
            }
            |> filter { $0 != nil }
            |> map { $0! }
        } else {
            file = .single(ForumUI.makeIconFile(title: info.title, iconColor: info.iconColor, isGeneral: isGeneral))
        }
        
        return file |> mapToSignal { file in
            let reference = FileMediaReference.standalone(media: file)
            let signal:Signal<ImageDataTransformation, NoError>
            
            let emptyColor: TransformImageEmptyColor?
            if isDefaultStatusesPackId(file.emojiReference) {
                emptyColor = .fill(theme.colors.accent)
            } else {
                emptyColor = nil
            }
            
            let aspectSize = file.dimensions?.size.aspectFilled(displayDimensions) ?? displayDimensions
            let arguments = TransformImageArguments(corners: ImageCorners(), imageSize: aspectSize, boundingSize: displayDimensions, intrinsicInsets: NSEdgeInsets(), emptyColor: emptyColor)
            
            switch file.mimeType {
            case "image/webp":
                signal = chatMessageSticker(postbox: account.postbox, file: reference, small: false, scale: System.backingScale, fetched: true)
            case "bundle/topic":
                if let resource = file.resource as? ForumTopicIconResource {
                    signal = makeTopicIcon(resource.title, bgColors: resource.bgColors, strokeColors: resource.strokeColors)
                } else {
                    signal = .complete()
                }
            case "bundle/jpeg":
                if let resource = file.resource as? LocalBundleResource {
                    signal = makeGeneralTopicIcon(resource)
                } else {
                    signal = .complete()
                }
            default:
                signal = chatMessageAnimatedSticker(postbox: account.postbox, file: reference, small: false, scale: System.backingScale, size: aspectSize, fetched: true, thumbAtFrame: 0, isVideo: file.fileName == "webm-preview" || file.isVideoSticker)
            }
            return signal |> map { data -> (CGImage?, Bool) in
                let context = data.execute(arguments, data.data)
                let image = context?.generateImage()
                return (image, true)
            }
        }
        #else
        return .complete()
        #endif
    }
}

/*

 */

enum EmptyAvatartType {
    case peer(colors:(top:NSColor, bottom: NSColor), letter: [String], font: NSFont, cornerRadius: CGFloat?)
    case icon(colors:(top:NSColor, bottom: NSColor), icon: CGImage, iconSize: NSSize, cornerRadius: CGFloat?)
}

func generateEmptyPhoto(_ displayDimensions:NSSize, type: EmptyAvatartType) -> Signal<CGImage?, NoError> {
    return Signal { subscriber in
        
        let color:(top: NSColor, bottom: NSColor)
        let letters: [String]?
        let icon: CGImage?
        let iconSize: NSSize?
        let font: NSFont?
        let cornerRadius: CGFloat?
        switch type {
        case let .icon(colors, _icon, _iconSize, _cornerRadius):
            color = colors
            icon = _icon
            letters = nil
            font = nil
            iconSize = _iconSize
            cornerRadius = _cornerRadius
        case let .peer(colors, _letters, _font, _cornerRadius):
            color = colors
            icon = nil
            font = _font
            letters = _letters
            iconSize = nil
            cornerRadius = _cornerRadius
        }
        
        let image = generateImage(displayDimensions, contextGenerator: { (size, ctx) in
            ctx.clear(NSMakeRect(0, 0, size.width, size.height))
            
            if let cornerRadius = cornerRadius {
                ctx.round(size, cornerRadius)
            } else {
                ctx.round(size, size.height / 2)
            }
            //ctx.addEllipse(in: CGRect(x: 0.0, y: 0.0, width: size.width, height:
             //   size.height))
           // ctx.clip()
            
            var locations: [CGFloat] = [1.0, 0.2];
            let colorSpace = deviceColorSpace
            let gradient = CGGradient(colorsSpace: colorSpace, colors: NSArray(array: [color.top.cgColor, color.bottom.cgColor]), locations: &locations)!
            
            ctx.drawLinearGradient(gradient, start: CGPoint(), end: CGPoint(x: 0.0, y: size.height), options: CGGradientDrawingOptions())
            
            ctx.setBlendMode(.normal)
            
            if let letters = letters, let font = font {
                let string = letters.count == 0 ? "" : (letters[0] + (letters.count == 1 ? "" : letters[1]))
                let attributedString = NSAttributedString(string: string, attributes: [NSAttributedString.Key.font: font, NSAttributedString.Key.foregroundColor: NSColor.white])
                
                let line = CTLineCreateWithAttributedString(attributedString)
                let lineBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                
                let lineOrigin = CGPoint(x: floorToScreenPixels(System.backingScale, -lineBounds.origin.x + (size.width - lineBounds.size.width) / 2.0) , y: floorToScreenPixels(System.backingScale, -lineBounds.origin.y + (size.height - lineBounds.size.height) / 2.0))
                
                ctx.translateBy(x: size.width / 2.0, y: size.height / 2.0)
                ctx.scaleBy(x: 1.0, y: 1.0)
                ctx.translateBy(x: -size.width / 2.0, y: -size.height / 2.0)
                //
                ctx.translateBy(x: lineOrigin.x, y: lineOrigin.y)
                CTLineDraw(line, ctx)
                ctx.translateBy(x: -lineOrigin.x, y: -lineOrigin.y)
            }
            
            if let icon = icon, let iconSize = iconSize {
                let rect = NSMakeRect((displayDimensions.width - iconSize.width)/2, (displayDimensions.height - iconSize.height)/2, iconSize.width, iconSize.height)
                ctx.draw(icon, in: rect)
            }
            
        })
        subscriber.putNext(image)
        subscriber.putCompletion()
        return EmptyDisposable
    }
}

func generateEmptyRoundAvatar(_ displayDimensions:NSSize, font: NSFont, account:Account, peer:Peer) -> Signal<CGImage?, NoError> {
    return Signal { subscriber in
        let letters = peer.displayLetters
        
        let index = peer.nameColor?.index ?? Int(abs(peer.id.id._internalGetInt64Value() % 7))
        let color = theme.colors.peerColors(index)
        
        let image = generateImage(displayDimensions, contextGenerator: { (size, ctx) in
            ctx.clear(NSMakeRect(0, 0, size.width, size.height))
            
            var locations: [CGFloat] = [1.0, 0.2];
            let colorSpace = deviceColorSpace
            let gradient = CGGradient(colorsSpace: colorSpace, colors: NSArray(array: [color.top.cgColor, color.bottom.cgColor]), locations: &locations)!
            
            ctx.drawLinearGradient(gradient, start: CGPoint(), end: CGPoint(x: 0.0, y: size.height), options: CGGradientDrawingOptions())
            
            ctx.setBlendMode(.normal)
            
            let letters = letters
            let string = letters.count == 0 ? "" : (letters[0] + (letters.count == 1 ? "" : letters[1]))
            let attributedString = NSAttributedString(string: string, attributes: [NSAttributedString.Key.font: font, NSAttributedString.Key.foregroundColor: NSColor.white])
            
            let line = CTLineCreateWithAttributedString(attributedString)
            let lineBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            
            let lineOrigin = CGPoint(x: floorToScreenPixels(System.backingScale, -lineBounds.origin.x + (size.width - lineBounds.size.width) / 2.0) , y: floorToScreenPixels(System.backingScale, -lineBounds.origin.y + (size.height - lineBounds.size.height) / 2.0))
            
            ctx.translateBy(x: size.width / 2.0, y: size.height / 2.0)
            ctx.scaleBy(x: 1.0, y: 1.0)
            ctx.translateBy(x: -size.width / 2.0, y: -size.height / 2.0)
            //
            ctx.translateBy(x: lineOrigin.x, y: lineOrigin.y)
            CTLineDraw(line, ctx)
            ctx.translateBy(x: -lineOrigin.x, y: -lineOrigin.y)
        })
        subscriber.putNext(image)
        subscriber.putCompletion()
        return EmptyDisposable
    }
    
    
}
