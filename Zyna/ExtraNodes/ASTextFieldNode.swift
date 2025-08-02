//
//  Based on the original Objective-C implementation in AsyncDisplayKit,
//  Copyright (c) 2014–present, Facebook, Inc.
//
//  SPDX-License-Identifier: BSD-3-Clause
//
//  Swift adaptation by Dmitry Markovsky, 2025
//
//  With thanks to Pocket Labs for their open-source Objective-C version
//  that inspired this Swift implementation:
//  https://github.com/pocketlabs/ASTextFieldNode
//

import AsyncDisplayKit
import UIKit

class ASTextFieldNode: ASDisplayNode {
    
    // MARK: - Properties
    
    private var textField: UITextField!
    private var _attributedPlaceholder: NSAttributedString?
    private var _textAlignment: NSTextAlignment = .left
    private var _text: String?
    private var _placeholder: String?
    private var _font: UIFont?
    private var _textColor: UIColor?
    private var _placeholderColor: UIColor?
    private var _keyboardType: UIKeyboardType = .default
    private var _returnKeyType: UIReturnKeyType = .default
    private var _borderStyle: UITextField.BorderStyle = .none
    private var _clearsOnBeginEditing: Bool = false
    private var _autocorrectionType: UITextAutocorrectionType = .default
    private var _autocapitalizationType: UITextAutocapitalizationType = .sentences
    private var _secureTextEntry: Bool = false
    private var _maxLength: Int = Int.max
    private var _delegate: ASTextFieldNodeDelegate?
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        setViewBlock { [weak self] in
            guard let self = self else { return UITextField() }
            
            let textField = UITextField()
            textField.delegate = self
            textField.addTarget(self, action: #selector(self.textFieldDidChange(_:)), for: .editingChanged)
            
            // Apply stored properties
            textField.text = self._text
            textField.placeholder = self._placeholder
            textField.font = self._font
            textField.textColor = self._textColor
            textField.textAlignment = self._textAlignment
            textField.keyboardType = self._keyboardType
            textField.returnKeyType = self._returnKeyType
            textField.borderStyle = self._borderStyle
            textField.clearsOnBeginEditing = self._clearsOnBeginEditing
            textField.autocorrectionType = self._autocorrectionType
            textField.autocapitalizationType = self._autocapitalizationType
            textField.isSecureTextEntry = self._secureTextEntry
            
            if let attributedPlaceholder = self._attributedPlaceholder {
                textField.attributedPlaceholder = attributedPlaceholder
            } else if let placeholder = self._placeholder, let placeholderColor = self._placeholderColor {
                textField.attributedPlaceholder = NSAttributedString(
                    string: placeholder,
                    attributes: [NSAttributedString.Key.foregroundColor: placeholderColor]
                )
            }
            
            self.textField = textField
            return textField
        }
    }
    
    // MARK: - UITextField Access
    override func didLoad() {
        super.didLoad()
        textField = view as? UITextField
    }
    
    // MARK: - Text Field Properties
    var attributedPlaceholder: NSAttributedString? {
        get { return _attributedPlaceholder }
        set {
            _attributedPlaceholder = newValue
            textField?.attributedPlaceholder = newValue
        }
    }
    
    var text: String? {
        get { return _text }
        set {
            _text = newValue
            textField?.text = newValue
        }
    }
    
    var placeholder: String? {
        get { return _placeholder }
        set {
            _placeholder = newValue
            textField?.placeholder = newValue
            
            if let color = _placeholderColor, let placeholder = newValue {
                textField?.attributedPlaceholder = NSAttributedString(
                    string: placeholder,
                    attributes: [NSAttributedString.Key.foregroundColor: color]
                )
            }
        }
    }
    
    var font: UIFont? {
        get { return _font }
        set {
            _font = newValue
            textField?.font = newValue
        }
    }
    
    var textColor: UIColor? {
        get { return _textColor }
        set {
            _textColor = newValue
            textField?.textColor = newValue
        }
    }
    
    var placeholderColor: UIColor? {
        get { return _placeholderColor }
        set {
            _placeholderColor = newValue
            if let placeholder = _placeholder, let color = newValue {
                textField?.attributedPlaceholder = NSAttributedString(
                    string: placeholder,
                    attributes: [NSAttributedString.Key.foregroundColor: color]
                )
            }
        }
    }
    
    var textAlignment: NSTextAlignment {
        get { return _textAlignment }
        set {
            _textAlignment = newValue
            textField?.textAlignment = newValue
        }
    }
    
    var keyboardType: UIKeyboardType {
        get { return _keyboardType }
        set {
            _keyboardType = newValue
            textField?.keyboardType = newValue
        }
    }
    
    var returnKeyType: UIReturnKeyType {
        get { return _returnKeyType }
        set {
            _returnKeyType = newValue
            textField?.returnKeyType = newValue
        }
    }
    
    var borderStyle: UITextField.BorderStyle {
        get { return _borderStyle }
        set {
            _borderStyle = newValue
            textField?.borderStyle = newValue
        }
    }
    
    var clearsOnBeginEditing: Bool {
        get { return _clearsOnBeginEditing }
        set {
            _clearsOnBeginEditing = newValue
            textField?.clearsOnBeginEditing = newValue
        }
    }
    
    var autocorrectionType: UITextAutocorrectionType {
        get { return _autocorrectionType }
        set {
            _autocorrectionType = newValue
            textField?.autocorrectionType = newValue
        }
    }
    
    var autocapitalizationType: UITextAutocapitalizationType {
        get { return _autocapitalizationType }
        set {
            _autocapitalizationType = newValue
            textField?.autocapitalizationType = newValue
        }
    }
    
    var secureTextEntry: Bool {
        get { return _secureTextEntry }
        set {
            _secureTextEntry = newValue
            textField?.isSecureTextEntry = newValue
        }
    }
    
    var maxLength: Int {
        get { return _maxLength }
        set { _maxLength = newValue }
    }
    
    weak var delegate: ASTextFieldNodeDelegate? {
        get { return _delegate }
        set { _delegate = newValue }
    }
    
    // MARK: - Text Field Methods
    override func becomeFirstResponder() -> Bool {
        return view.becomeFirstResponder()
    }
    
    override func resignFirstResponder() -> Bool {
        return view.resignFirstResponder()
    }
    
    // MARK: - Text Field Notifications
    @objc private func textFieldDidChange(_ textField: UITextField) {
        _text = textField.text
        
        // Apply max length if needed
        if let text = textField.text, text.count > _maxLength {
            textField.text = String(text.prefix(_maxLength))
            _text = textField.text
        }
        
        delegate?.textFieldDidChange(self)
    }
}

// MARK: - UITextFieldDelegate

extension ASTextFieldNode: UITextFieldDelegate {
    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        return delegate?.textFieldShouldBeginEditing(self) ?? true
    }
    
    func textFieldDidBeginEditing(_ textField: UITextField) {
        delegate?.textFieldDidBeginEditing(self)
    }
    
    func textFieldShouldEndEditing(_ textField: UITextField) -> Bool {
        return delegate?.textFieldShouldEndEditing(self) ?? true
    }
    
    func textFieldDidEndEditing(_ textField: UITextField) {
        delegate?.textFieldDidEndEditing(self)
    }
    
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        // Max length validation
        if let text = textField.text {
            let newLength = text.count + string.count - range.length
            if newLength > _maxLength {
                return false
            }
        }
        
        return delegate?.textField(self, shouldChangeCharactersIn: range, replacementString: string) ?? true
    }
    
    func textFieldShouldClear(_ textField: UITextField) -> Bool {
        return delegate?.textFieldShouldClear(self) ?? true
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        return delegate?.textFieldShouldReturn(self) ?? true
    }
}

// MARK: - ASTextFieldNode Delegate

protocol ASTextFieldNodeDelegate: AnyObject {
    func textFieldShouldBeginEditing(_ textField: ASTextFieldNode) -> Bool
    func textFieldDidBeginEditing(_ textField: ASTextFieldNode)
    func textFieldShouldEndEditing(_ textField: ASTextFieldNode) -> Bool
    func textFieldDidEndEditing(_ textField: ASTextFieldNode)
    func textField(_ textField: ASTextFieldNode, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool
    func textFieldShouldClear(_ textField: ASTextFieldNode) -> Bool
    func textFieldShouldReturn(_ textField: ASTextFieldNode) -> Bool
    func textFieldDidChange(_ textField: ASTextFieldNode)
}

// Default implementations to make the protocol methods optional
extension ASTextFieldNodeDelegate {
    func textFieldShouldBeginEditing(_ textField: ASTextFieldNode) -> Bool { return true }
    func textFieldDidBeginEditing(_ textField: ASTextFieldNode) {}
    func textFieldShouldEndEditing(_ textField: ASTextFieldNode) -> Bool { return true }
    func textFieldDidEndEditing(_ textField: ASTextFieldNode) {}
    func textField(_ textField: ASTextFieldNode,
                   shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool { return true }
    func textFieldShouldClear(_ textField: ASTextFieldNode) -> Bool { return true }
    func textFieldShouldReturn(_ textField: ASTextFieldNode) -> Bool { return true }
    func textFieldDidChange(_ textField: ASTextFieldNode) {}
}
