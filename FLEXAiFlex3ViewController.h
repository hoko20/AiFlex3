#import <UIKit/UIKit.h>

// AiFlex3 control surface. Runs entirely inside the injected app: it shows the
// in-process MCP service state, the current FLEX selection and the grants that
// gate each tool group. It also hosts the window operations exposed to MCP.
@interface FLEXAiFlex3ViewController : UIViewController

@property (nonatomic, weak) id selectedObject;

- (instancetype)initWithReport:(NSString *)report className:(NSString *)className;
- (void)updateReport:(NSString *)report className:(NSString *)className selectedObject:(id)object;

// Used by the in-app MCP endpoint to reach the window operations that belong
// to this panel. Returns nil once the panel has been released.
+ (instancetype)aiFlex3CurrentPanel;
- (void)performWindowOperation:(NSString *)operation
                     arguments:(NSDictionary *)arguments
                    completion:(void (^)(NSDictionary *result, NSString *error))completion;

@end
