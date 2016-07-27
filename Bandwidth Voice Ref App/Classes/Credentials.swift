//
//  Credentials.swift
//  Bandwidth Voice Ref App
//
//  Created by Fabio Rodella on 4/6/15.
//  Copyright (c) 2015 Bandwidth. All rights reserved.
//

import Foundation

/**
    Structure describing a set of SIP credentials
*/
struct Credentials {
    
    let username: String
        
    let realm: String
    
    static func fromJSON(json: [String: AnyObject]) -> Credentials? {
        
        let username    = json["username"] as? String
        let realm       = json["realm"] as? String
        
        if (username != nil &&
            realm != nil) {
                
            return Credentials(username: username!, realm: realm!)
        }
        
        return nil
    }
    
    func toJSON() -> [String: AnyObject] {
        
        return ["username"  : username,
                "realm"     : realm]
    }
}
