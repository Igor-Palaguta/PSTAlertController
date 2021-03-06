//
//  PSTAlertController.m
//
//  Copyright (c) 2014 PSPDFKit GmbH. All rights reserved.
//
//  THIS SOURCE CODE AND ANY ACCOMPANYING DOCUMENTATION ARE PROTECTED BY INTERNATIONAL COPYRIGHT LAW
//  AND MAY NOT BE RESOLD OR REDISTRIBUTED. USAGE IS BOUND TO THE PSPDFKIT LICENSE AGREEMENT.
//  UNAUTHORIZED REPRODUCTION OR DISTRIBUTION IS SUBJECT TO CIVIL AND CRIMINAL PENALTIES.
//  This notice may not be removed from this file.
//

#import "PSTAlertController.h"
#import <objc/runtime.h>

#define PROPERTY(property) NSStringFromSelector(@selector(property))

@interface PSTAlertAction ()
@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) PSTAlertActionStyle style;
@property (nonatomic, copy) void (^handler)(PSTAlertAction *action);
- (void)performAction;
@end

@implementation PSTAlertAction

+ (instancetype)actionWithTitle:(NSString *)title style:(PSTAlertActionStyle)style handler:(void (^)(PSTAlertAction *action))handler {
    return [[self alloc] initWithTitle:title style:style handler:handler];
}

+ (instancetype)actionWithTitle:(NSString *)title handler:(void (^)(PSTAlertAction *action))handler {
    return [[self alloc] initWithTitle:title style:PSTAlertActionStyleDefault handler:handler];
}

- (instancetype)initWithTitle:(NSString *)title style:(PSTAlertActionStyle)style handler:(void (^)(PSTAlertAction *action))handler {
    if ((self = [super init])) {
        _title = [title copy];
        _style = style;
        _handler = [handler copy];
    }
    return self;
}

- (void)performAction {
    if (self.handler) {
        self.handler(self);
        self.handler = nil; // nil out after calling to break cycles.
    }
}

@end

@interface PSTExtendedAlertController : UIAlertController
@property (nonatomic, copy) void (^viewWillDisappearBlock)(void);
@property (nonatomic, copy) void (^viewDidDisappearBlock)(void);
@end

@implementation PSTExtendedAlertController

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.viewWillDisappearBlock) self.viewWillDisappearBlock();
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.viewDidDisappearBlock) self.viewDidDisappearBlock();
}

@end

@interface PSTAlertController () <UIActionSheetDelegate, UIAlertViewDelegate> {
    struct {
        unsigned int isShowingAlert:1;
    } _flags;
}
- (instancetype)initWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(PSTAlertControllerStyle)preferredStyle NS_DESIGNATED_INITIALIZER;

@property (nonatomic, copy) NSArray *willDismissBlocks;
@property (nonatomic, copy) NSArray *didDismissBlocks;
@property (nonatomic, copy) PSTAlertControllerPredicate buttonEnabledPredicate;

// Universal
@property (nonatomic, weak) PSTAlertAction *executedAlertAction;

// iOS 7
@property (nonatomic, copy) NSArray *actions;
@property (nonatomic, copy) NSArray *textFieldHandlers;
@property (nonatomic, strong, readonly) UIActionSheet *actionSheet;
@property (nonatomic, strong, readonly) UIAlertView *alertView;

// Storage for actionSheet/alertView/alertController
@property (nonatomic, strong) id strongSheetStorage;
@property (nonatomic, weak) id weakSheetStorage;
@end

@implementation PSTAlertController

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Initialization

- (BOOL)alertControllerAvailable {
    return [UIAlertController class] != nil; // iOS 8 and later.
}

+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(PSTAlertControllerStyle)preferredStyle {
    return [[self alloc] initWithTitle:title message:message preferredStyle:preferredStyle];
}

- (instancetype)initWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(PSTAlertControllerStyle)preferredStyle {
    if ((self = [super init])) {
        _title = [title copy];
        _message = [message copy];
        _preferredStyle = preferredStyle;

        if ([self alertControllerAvailable]) {
            _strongSheetStorage = [PSTExtendedAlertController alertControllerWithTitle:title message:message preferredStyle:(UIAlertControllerStyle)preferredStyle];
        }
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, title:%@, actions:%@>", NSStringFromClass(self.class), self, self.title, self.actions];
}

- (void)dealloc {
    // In case the alert controller can't be displayed for any reason,
    // We'd still increment the counter and need to do the cleanup work here.
    [self setIsShowingAlert:NO];
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Accessors

- (UIView *)lazySheetStorage {
#if __IPHONE_OS_VERSION_MIN_REQUIRED < 80000
    NSParameterAssert(![self alertControllerAvailable]);
    if ([self alertControllerAvailable]) {
        return nil;
    }

    //First button is required for proper disable
    id sheetStorage = nil;
    NSArray* otherActions = self.actions;
    if (self.preferredStyle == PSTAlertControllerStyleAlert) {
        __block PSTAlertAction* firstButtonAction = nil;
        __block PSTAlertAction* cancelButtonAction = nil;
        NSMutableArray* unusedDuringInitActions = [self.actions mutableCopy];
        [self.actions enumerateObjectsUsingBlock: ^(PSTAlertAction* action, NSUInteger index, BOOL *stop) {
            if (action.style == PSTAlertActionStyleDefault || action.style == PSTAlertActionStyleDestructive) {
                firstButtonAction = action;
                [unusedDuringInitActions removeObject: action];
                *stop = YES;
            } else if (action.style == PSTAlertActionStyleCancel) {
                cancelButtonAction = action;
                [unusedDuringInitActions removeObject: action];
            }
        }];

        NSMutableArray* allActions = [NSMutableArray array];
        if (cancelButtonAction) {
            [allActions addObject: cancelButtonAction];
        }

        if (firstButtonAction) {
            [allActions addObject: firstButtonAction];
        }

        otherActions = unusedDuringInitActions;
        self.actions = [allActions arrayByAddingObjectsFromArray: otherActions];

        sheetStorage = [[UIAlertView alloc] initWithTitle:self.title message:self.message delegate:self cancelButtonTitle:cancelButtonAction.title otherButtonTitles:firstButtonAction.title, nil];

        if ([self.textFieldHandlers count] > 0) {
            UIAlertViewStyle style = self.textFieldHandlers.count > 1 ? UIAlertViewStyleLoginAndPasswordInput : UIAlertViewStylePlainTextInput;
            [sheetStorage setAlertViewStyle:style];

            [self.textFieldHandlers enumerateObjectsUsingBlock:^(void (^configurationHandler)(UITextField *textField), NSUInteger idx, BOOL *stop) {
                configurationHandler([sheetStorage textFieldAtIndex:idx]);
            }];
        }
    } else {
        sheetStorage = [[UIActionSheet alloc] initWithTitle:self.title delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil, nil];
    }

    for (PSTAlertAction* action in otherActions)
    {
        if (self.preferredStyle == PSTAlertControllerStyleActionSheet) {
            NSUInteger currentButtonIndex = [sheetStorage addButtonWithTitle:action.title];
            
            if (action.style == PSTAlertActionStyleDestructive) {
                [sheetStorage setDestructiveButtonIndex: currentButtonIndex];
            } else if (action.style == PSTAlertActionStyleCancel) {
                [sheetStorage setCancelButtonIndex: currentButtonIndex];
            }
        } else {
            NSUInteger currentButtonIndex = [sheetStorage addButtonWithTitle:action.title];
            if (action.style == PSTAlertActionStyleCancel) {
                [sheetStorage setCancelButtonIndex: currentButtonIndex];
            }
        }
    }

    return sheetStorage;
#else
    return nil;
#endif
}

- (id)strongSheetStorage {
    if ([self alertControllerAvailable]) {
        return _strongSheetStorage;
    }

    if (!_strongSheetStorage && !self.weakSheetStorage) {
        _strongSheetStorage = [self lazySheetStorage];
    }
    return _strongSheetStorage;
}

-(id)alert {
    return self.strongSheetStorage ?: self.weakSheetStorage;
}

- (UIAlertView *)alertView {
    return (UIAlertView *)[self alert];
}

- (UIActionSheet *)actionSheet {
    return (UIActionSheet *)[self alert];
}

- (UIAlertController *)alertController {
    return (UIAlertController *)[self alert];
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Adding Actions

- (void)addAction:(PSTAlertAction *)action {
    NSAssert([action isKindOfClass:PSTAlertAction.class], @"Must be of type PSTAlertAction");

    action.alertController = self; // weakly connect

    self.actions = [[NSArray arrayWithArray:self.actions] arrayByAddingObject:action];

    if ([self alertControllerAvailable]) {
        UIAlertAction *alertAction = [UIAlertAction actionWithTitle:action.title style:(UIAlertActionStyle)action.style handler:^(UIAlertAction *uiAction) {
            //retain self, otherwise action.alertController can return nil. No cyclic reference after alert is shown.
            self.executedAlertAction = action;
            [action performAction];
        }];
        [self.alertController addAction:alertAction];
    }
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Text Field Support

- (void)disableFirstButtonIfNeeded {
    if (self.buttonEnabledPredicate) {
        for (UIAlertAction* action in self.alertController.actions) {
            if (action.style == UIAlertActionStyleDefault) {
                action.enabled = self.buttonEnabledPredicate(self);
                return;
            }
        }
    }
}

- (void)textFieldDidChange:(UITextField *)textField {
    [self disableFirstButtonIfNeeded];
}

- (void)addTextFieldWithConfigurationHandler:(void (^)(UITextField *textField))configurationHandler {
    if ([self alertControllerAvailable]) {
        __weak typeof (self) weakSelf = self;
        [self.alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            typeof (self) strongSelf = weakSelf;
            [textField addTarget:strongSelf action:@selector(textFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
            if (configurationHandler) {
                configurationHandler(textField);
            }
        }];
    } else {
        NSAssert(self.preferredStyle == PSTAlertControllerStyleAlert, @"Text fields are only supported for alerts.");
        self.textFieldHandlers = [[NSArray arrayWithArray:self.textFieldHandlers] arrayByAddingObject:configurationHandler ?: ^(UITextField *textField){}];
    }
}

- (NSArray *)textFields {
    if ([self alertControllerAvailable]) {
        return self.alertController.textFields;
    } else if (self.preferredStyle == PSTAlertControllerStyleAlert) {
        switch (self.alertView.alertViewStyle) {
            case UIAlertViewStyleSecureTextInput:
            case UIAlertViewStylePlainTextInput:
                return @[[self.alertView textFieldAtIndex:0]];
            case UIAlertViewStyleLoginAndPasswordInput:
                return @[[self.alertView textFieldAtIndex:0], [self.alertView textFieldAtIndex:1]];
            case UIAlertViewStyleDefault:
                return @[];
        }
    }
    // UIActionSheet doesn't support text fields.
    return nil;
}

- (UITextField *)textField {
    return self.textFields.firstObject;
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Presentation

static NSUInteger PSTVisibleAlertsCount = 0;
+ (BOOL)hasVisibleAlertController {
    return PSTVisibleAlertsCount > 0;
}

- (BOOL)isVisible {
    if ([self alertControllerAvailable]) {
        return self.alertController.view.window != nil;
    } else {
        if (self.preferredStyle == PSTAlertControllerStyleActionSheet) {
            return self.actionSheet.isVisible;
        } else {
            return self.alertView.isVisible;
        }
    }
}

- (void)showWithSender:(id)sender controller:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    if ([self alertControllerAvailable]) {
        // As a convenience, allow automatic root view controller fetching if we show an alert.
        if (self.preferredStyle == PSTAlertControllerStyleAlert) {
            if (!controller) {
                // sharedApplication is unavailable for extensions, but required for things like preferredContentSizeCategory.
                UIApplication *sharedApplication = [UIApplication performSelector:NSSelectorFromString(PROPERTY(sharedApplication))];
                controller = sharedApplication.keyWindow.rootViewController;
            }
            
            // Use the frontmost viewController for presentation.
            while (controller.presentedViewController) {
                controller = controller.presentedViewController;
            }
            
            if (!controller) {
                NSLog(@"Can't show alert because there is no root view controller.");
                return;
            }
        }

        // We absolutely need a controller going forward.
        NSParameterAssert(controller);

        PSTExtendedAlertController *alertController = (PSTExtendedAlertController *)self.alertController;
        UIPopoverPresentationController *popoverPresentation = alertController.popoverPresentationController;
        if (popoverPresentation) { // nil on iPhone
            if ([sender isKindOfClass:UIBarButtonItem.class]) {
                popoverPresentation.barButtonItem = sender;
            } else if ([sender isKindOfClass:UIView.class]) {
                popoverPresentation.sourceView = sender;
                popoverPresentation.sourceRect = [sender bounds];
            } else if ([sender isKindOfClass:NSValue.class]) {
                popoverPresentation.sourceView = controller.view;
                popoverPresentation.sourceRect = [sender CGRectValue];
            } else {
                popoverPresentation.sourceView = controller.view;
                popoverPresentation.sourceRect = controller.view.bounds;
            }

            // Workaround for rdar://18921595. Unsatisfiable constraints when presenting UIAlertController.
            // If the rect is too large, the action sheet can't be displayed.
            CGRect r = popoverPresentation.sourceRect, screen = UIScreen.mainScreen.bounds;
            if (CGRectGetHeight(r) > CGRectGetHeight(screen)*0.5 || CGRectGetWidth(r) > CGRectGetWidth(screen)*0.5) {
                popoverPresentation.sourceRect = CGRectMake(r.origin.x + r.size.width/2.f, r.origin.y + r.size.height/2.f, 1.f, 1.f);
            }
        }

        // Hook up dismiss blocks.
        __weak typeof (self) weakSelf = self;
        alertController.viewWillDisappearBlock = ^{
            typeof (self) strongSelf = weakSelf;
            [strongSelf performBlocks:PROPERTY(willDismissBlocks) withAction:strongSelf.executedAlertAction];
            [strongSelf setIsShowingAlert:NO];
        };
        alertController.viewDidDisappearBlock = ^{
            typeof (self) strongSelf = weakSelf;
            [strongSelf performBlocks:PROPERTY(didDismissBlocks) withAction:strongSelf.executedAlertAction];
        };

        [self disableFirstButtonIfNeeded];
        [controller presentViewController:alertController animated:animated completion:nil];
    } else {
        if (self.preferredStyle == PSTAlertControllerStyleActionSheet) {
            [self showActionSheetWithSender:sender fallbackView:controller.view animated:animated];
        } else {
            [self.alertView show];
        }
    }

    [self moveSheetToWeakStorage];
    [self setIsShowingAlert:YES];
}

- (void)setIsShowingAlert:(BOOL)isShowing {
    if (_flags.isShowingAlert != isShowing) {
        _flags.isShowingAlert = isShowing;
        if (isShowing) {
            PSTVisibleAlertsCount++;
        } else {
            PSTVisibleAlertsCount--;
        }
    }
}

- (void)showActionSheetWithSender:(id)sender fallbackView:(UIView *)view animated:(BOOL)animated {
    UIActionSheet *actionSheet = self.actionSheet;
    BOOL isIPad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
    if (isIPad && [sender isKindOfClass:UIBarButtonItem.class]) {
        [actionSheet showFromBarButtonItem:sender animated:animated];
    } else if ([sender isKindOfClass:UIToolbar.class]) {
        [actionSheet showFromToolbar:sender];
    } else if ([sender isKindOfClass:UITabBar.class]) {
        [actionSheet showFromTabBar:sender];
    } else if ([view isKindOfClass:UIToolbar.class]) {
        [actionSheet showFromToolbar:(UIToolbar *)view];
    } else if ([view isKindOfClass:UITabBar.class]) {
        [actionSheet showFromTabBar:(UITabBar *)view];
    } else if (isIPad && [sender isKindOfClass:UIView.class]) {
        [actionSheet showFromRect:[sender bounds] inView:sender animated:animated];
    } else if ([sender isKindOfClass:NSValue.class]) {
        [actionSheet showFromRect:[sender CGRectValue] inView:view animated:animated];
    } else {
        [actionSheet showInView:view];
    }
}

- (void)dismissAnimated:(BOOL)animated completion:(void (^)(void))completion {
    if ([self alertControllerAvailable]) {
        [self.alertController dismissViewControllerAnimated:animated completion:completion];
    } else {
        // Make sure the completion block is called.
        if (completion) {
            [self addDidDismissBlock:^(PSTAlertAction *action) { completion(); }];
        }
        if (self.preferredStyle == PSTAlertControllerStyleActionSheet) {
            [self.actionSheet dismissWithClickedButtonIndex:self.actionSheet.cancelButtonIndex animated:animated];
        } else {
            [self.alertView dismissWithClickedButtonIndex:self.alertView.cancelButtonIndex animated:animated];
        }
    }
}

- (id)presentedObject {
    if ([self alertControllerAvailable]) {
        return self.alertController;
    } else {
        if (self.preferredStyle == PSTAlertControllerStyleActionSheet) {
            return self.actionSheet;
        } else {
            return self.alertView;
        }
    }
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Will/Did Dismiss Observers

- (void)addWillDismissBlock:(void (^)(PSTAlertAction *action))willDismissBlock {
    NSParameterAssert(willDismissBlock);
    self.willDismissBlocks = [[NSArray arrayWithArray:self.willDismissBlocks] arrayByAddingObject:willDismissBlock];
}

- (void)addDidDismissBlock:(void (^)(PSTAlertAction *action))didDismissBlock {
    NSParameterAssert(didDismissBlock);
    self.didDismissBlocks = [[NSArray arrayWithArray:self.didDismissBlocks] arrayByAddingObject:didDismissBlock];
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Memory Management

- (void)moveSheetToWeakStorage {
    NSParameterAssert(self.strongSheetStorage);

    objc_setAssociatedObject(self.strongSheetStorage, _cmd, self, OBJC_ASSOCIATION_RETAIN_NONATOMIC); // bind lifetime
    self.weakSheetStorage = self.strongSheetStorage;
    self.strongSheetStorage = nil;
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Execute Actions

- (PSTAlertAction *)actionForButtonIndex:(NSInteger)index {
    return index >= 0 ? self.actions[index] : nil;
}

- (void)performBlocks:(NSString *)blocksStorageName withAction:(PSTAlertAction *)alertAction {
    // Load variable and nil out.
    NSArray *blocks = [self valueForKey:blocksStorageName];
    [self setValue:nil forKey:blocksStorageName];

    for (void (^block)(PSTAlertAction *action) in blocks) {
        block(alertAction);
    }
}

- (void)viewWillDismissWithButtonIndex:(NSInteger)buttonIndex {
    PSTAlertAction *action = [self actionForButtonIndex:buttonIndex];
    self.executedAlertAction = action;

    [self performBlocks:PROPERTY(willDismissBlocks) withAction:action];
    self.willDismissBlocks = nil;

    [self setIsShowingAlert:NO];
}

- (void)viewDidDismissWithButtonIndex:(NSInteger)buttonIndex {
    PSTAlertAction *action = [self actionForButtonIndex:buttonIndex];
    [action performAction];

    [self performBlocks:PROPERTY(didDismissBlocks) withAction:action];
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - UIActionSheetDelegate

- (void)actionSheet:(UIActionSheet *)actionSheet willDismissWithButtonIndex:(NSInteger)buttonIndex {
    [self viewWillDismissWithButtonIndex:buttonIndex];
}

// Called when a button is clicked. The view will be automatically dismissed after this call returns.
- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex {
    [self viewDidDismissWithButtonIndex:buttonIndex];
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView willDismissWithButtonIndex:(NSInteger)buttonIndex {
    [self viewWillDismissWithButtonIndex:buttonIndex];
}

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
    [self viewDidDismissWithButtonIndex:buttonIndex];
}

- (BOOL)alertViewShouldEnableFirstOtherButton:(UIAlertView *)alertView {
    if (self.buttonEnabledPredicate && !self.buttonEnabledPredicate(self)) {
        return NO;
    }

    return YES;
}

@end

@implementation PSTAlertController (Convenience)

+ (instancetype)actionWithTitle:(NSString *)title handler:(void (^)(PSTAlertAction *action))handler {
    return [[self alloc] initWithTitle:title style:PSTAlertActionStyleDefault handler:handler];
}

+ (instancetype)alertWithTitle:(NSString *)title message:(NSString *)message {
    return [[self alloc] initWithTitle:title message:message preferredStyle:PSTAlertControllerStyleAlert];
}

+ (instancetype)actionSheetWithTitle:(NSString *)title {
    return [[self alloc] initWithTitle:title message:nil preferredStyle:PSTAlertControllerStyleActionSheet];
}

+ (instancetype)presentDismissableAlertWithTitle:(NSString *)title message:(NSString *)message controller:(UIViewController *)controller {
    PSTAlertController *alertController = [self alertWithTitle:title message:message];
    [alertController addAction:[PSTAlertAction actionWithTitle:NSLocalizedString(@"Dismiss", @"") style:PSTAlertActionStyleCancel handler:NULL]];
    [alertController showWithSender:nil controller:controller animated:YES completion:NULL];
    return alertController;
}

+ (instancetype)presentDismissableAlertWithTitle:(NSString *)title error:(NSError *)error controller:(UIViewController *)controller {
    NSString *message = error.localizedDescription;
    if (error.localizedFailureReason.length > 0) {
        message = [NSString stringWithFormat:@"%@ (%@)", error.localizedDescription, error.localizedFailureReason];
    }

    return [self presentDismissableAlertWithTitle:title message:message controller:controller];
}

- (void)addCancelActionWithHandler:(void (^)(PSTAlertAction *action))handler {
    [self addAction:[PSTAlertAction actionWithTitle:NSLocalizedString(@"Cancel", @"") style:PSTAlertActionStyleCancel handler:handler]];
}

- (void)setFirstButtonEnabledPredicate:(PSTAlertControllerPredicate)firstButtonEnabledPredicate {
    NSParameterAssert(self.preferredStyle == PSTAlertControllerStyleAlert);
    self.buttonEnabledPredicate = firstButtonEnabledPredicate;
}

@end
