#import "MTDDirectionsParserGoogle.h"
#import "MTDDirectionsOverlay.h"
#import "MTDXMLElement.h"
#import "MTDDistance.h"
#import "MTDFunctions.h"
#import "MTDWaypoint.h"
#import "MTDLogging.h"
#import "MTDStatusCodeGoogle.h"


@interface MTDDirectionsParserGoogle ()

- (NSArray *)waypointsFromEncodedPolyline:(NSString *)encodedPolyline;

@end


@implementation MTDDirectionsParserGoogle

////////////////////////////////////////////////////////////////////////
#pragma mark - MTDirectionsParser
////////////////////////////////////////////////////////////////////////

- (void)parseWithCompletion:(mtd_parser_block)completion {
    NSArray *statusCodeNodes = [MTDXMLElement nodesForXPathQuery:@"//DirectionsResponse/status" onXML:self.data];
    MTDStatusCodeGoogle statusCode = MTDStatusCodeGoogleSuccess;
    MTDDirectionsOverlay *overlay = nil;
    NSError *error = nil;
    
    if (statusCodeNodes.count > 0) {
        statusCode = MTDStatusCodeGoogleFromDescription([[statusCodeNodes objectAtIndex:0] contentString]);
    }
    
    if (statusCode == MTDStatusCodeGoogleSuccess) {
        NSArray *waypointNodes = [MTDXMLElement nodesForXPathQuery:@"//route[1]/leg[1]/step/polyline/points" onXML:self.data];
        NSArray *distanceNodes = [MTDXMLElement nodesForXPathQuery:@"//route[1]/leg[1]/distance/value" onXML:self.data];
        NSArray *timeNodes = [MTDXMLElement nodesForXPathQuery:@"//route[1]/leg[1]/duration/value" onXML:self.data];
        NSArray *copyrightNodes = [MTDXMLElement nodesForXPathQuery:@"//route[1]/copyrights" onXML:self.data];
        NSArray *warningNodes = [MTDXMLElement nodesForXPathQuery:@"//route[1]/warnings" onXML:self.data];
        
        NSMutableArray *waypoints = [NSMutableArray array];
        MTDDistance *distance = nil;
        NSTimeInterval timeInSeconds = -1.;
        NSMutableDictionary *additionalInfo = [NSMutableDictionary dictionary];
        
        // Parse Waypoints
        {
            // add start coordinate
            if (CLLocationCoordinate2DIsValid(self.fromCoordinate)) {
                [waypoints addObject:[MTDWaypoint waypointWithCoordinate:self.fromCoordinate]];
            }
            
            for (MTDXMLElement *waypointNode in waypointNodes) {
                NSString *encodedPolyline = [waypointNode contentString];
                
                [waypoints addObjectsFromArray:[self waypointsFromEncodedPolyline:encodedPolyline]];
            }
            
            // add end coordinate
            if (CLLocationCoordinate2DIsValid(self.toCoordinate)) {
                [waypoints addObject:[MTDWaypoint waypointWithCoordinate:self.toCoordinate]];
            }
        }
        
        // Parse Additional Info of directions
        {
            if (distanceNodes.count > 0) {
                double distanceInMeters = [[[distanceNodes objectAtIndex:0] contentString] doubleValue];
                distance = [MTDDistance distanceWithMeters:distanceInMeters];
            }
            
            if (timeNodes.count > 0) {
                timeInSeconds = [[[timeNodes objectAtIndex:0] contentString] doubleValue];
            }
            
            if (copyrightNodes.count > 0) {
                NSString *copyright = [[copyrightNodes objectAtIndex:0] contentString];
                [additionalInfo setValue:copyright forKey:@"copyrights"];
            }
            
            if (warningNodes.count > 0) {
                NSArray *warnings = [warningNodes valueForKey:@"contentString"];
                [additionalInfo setValue:warnings forKey:@"warnings"];
            }
            
            if (self.fromAddress == nil) {
                NSArray *fromAddressNodes = [MTDXMLElement nodesForXPathQuery:@"//route[1]/leg[1]/start_address" onXML:self.data];
                
                if (fromAddressNodes.count > 0) {
                    self.fromAddress = [[fromAddressNodes objectAtIndex:0] contentString];
                }
            }
            
            if (self.toAddress == nil) {
                NSArray *toAddressNodes = [MTDXMLElement nodesForXPathQuery:@"//route[1]/leg[1]/end_address" onXML:self.data];
                
                if (toAddressNodes.count > 0) {
                    self.toAddress = [[toAddressNodes objectAtIndex:0] contentString];
                }
            }
        }
        
        overlay = [MTDDirectionsOverlay overlayWithWaypoints:[waypoints copy]
                                                    distance:distance
                                               timeInSeconds:timeInSeconds
                                                   routeType:self.routeType];

        // set read-only properties via KVO to not pollute API
        [overlay setValue:self.fromAddress forKey:NSStringFromSelector(@selector(fromAddress))];
        [overlay setValue:self.toAddress forKey:NSStringFromSelector(@selector(toAddress))];
        [overlay setValue:additionalInfo forKey:NSStringFromSelector(@selector(additionalInfo))];
    } else {
        error = [NSError errorWithDomain:MTDDirectionsKitErrorDomain
                                    code:statusCode
                                userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
                                          self.data, MTDDirectionsKitDataKey,
                                          nil]];
        
        MTDLogError(@"Error occurred during parsing of directions from %@ to %@:\n%@", 
                    MTDStringFromCLLocationCoordinate2D(self.fromCoordinate),
                    MTDStringFromCLLocationCoordinate2D(self.toCoordinate),
                    error);
    }
    
    if (completion != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(overlay, error);
        });
    } else {
        MTDLogWarning(@"No completion block was set.");
    }
}

////////////////////////////////////////////////////////////////////////
#pragma mark - Private
////////////////////////////////////////////////////////////////////////

// Algorithm description:
// http://code.google.com/apis/maps/documentation/utilities/polylinealgorithm.html
- (NSArray *)waypointsFromEncodedPolyline:(NSString *)encodedPolyline {
    const char *bytes = [encodedPolyline UTF8String];
    NSUInteger length = [encodedPolyline lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    NSUInteger index = 0;
    double latitude = 0.;
    double longitude = 0.;
    NSMutableArray *waypoints = [NSMutableArray array];
    
    while (index < length) {
        char byte = 0;
        int res = 0;
        char shift = 0;
        
        do {
            byte = bytes[index++] - 63;
            res |= (byte & 0x1F) << shift;
            shift += 5;
        } while (byte >= 0x20);
        
        float deltaLat = ((res & 1) ? ~(res >> 1) : (res >> 1));
        latitude += deltaLat;
        
        shift = 0;
        res = 0;
        
        do {
            byte = bytes[index++] - 0x3F;
            res |= (byte & 0x1F) << shift;
            shift += 5;
        } while (byte >= 0x20);
        
        double deltaLon = ((res & 1) ? ~(res >> 1) : (res >> 1));
        longitude += deltaLon;
        
        CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(latitude * 1E-5, longitude * 1E-5);
        [waypoints addObject:[MTDWaypoint waypointWithCoordinate:coordinate]];
    }
    
    return [waypoints copy];
}

@end