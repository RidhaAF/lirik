//
//  LirikWidget.swift
//  lirik
//
//  Created by Ridha Ahmad Firdaus on 05/08/26.
//  
//

import Foundation
import AppKit
import PockKit

class LirikWidget: PKWidget {
    
    static var identifier: String = "io.github.ridhaaf.lirik"
    var customizationLabel: String = "lirik"
    var view: NSView!
    
    required init() {
        self.view = PKButton(title: "lirik", target: self, action: #selector(printMessage))
    }
    
    @objc private func printMessage() {
        NSLog("[LirikWidget]: Hello, World!")
    }
    
}
