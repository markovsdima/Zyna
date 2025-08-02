//
//  BaseNode.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 17.04.2025.
//

import AsyncDisplayKit

class BaseNode: ASDisplayNode {
    
    override init() {
        super.init()
        self.automaticallyManagesSubnodes = true
        self.backgroundColor = UIColor.appBG
    }
}
