//
//  AuthViewModel.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 04.07.2025.
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
