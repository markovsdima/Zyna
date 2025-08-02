//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import RxFlow
import RxRelay

final class AuthViewModel: ObservableObject, RxFlow.Stepper {
    
    let steps = PublishRelay<Step>() // navigation steps flow
    
    func proceedToMainFlow() {
        steps.accept(AppStep.mainFlow)
    }
    
    func showError() {
        // steps.accept(AuthStep.error)
    }
}
