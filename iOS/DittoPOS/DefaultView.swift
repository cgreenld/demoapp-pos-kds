///
//  DefaultView.swift
//  DittoPOS
//

import SwiftUI

struct DefaultView: View {
    let number: String
    
    var body: some View {
        ZStack {
            Color.white  // Blank/white background
                .ignoresSafeArea()
            
            VStack {
                Text(number)
                    .font(.system(size: 120, weight: .bold))
                    .foregroundColor(.black)
            }
        }
    }
}

