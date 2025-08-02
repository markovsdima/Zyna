//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

class BaseNode: ASDisplayNode {
    
    override init() {
        super.init()
        self.automaticallyManagesSubnodes = true
        self.backgroundColor = UIColor.appBG
    }
}
