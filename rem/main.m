//
//  main.m
//  rem
//
//  Created by Kevin Y. Kim on 10/15/12.
//  Copyright (c) 2012 kykim, inc. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <EventKit/EventKit.h>

#define COMMANDS @[ @"ls", @"add", @"rm", @"cat", @"done", @"event", @"cal", @"help", @"version" ]
typedef enum my_CommandType {
    CMD_UNKNOWN = -1,
    CMD_LS = 0,
    CMD_ADD,
    CMD_RM,
    CMD_CAT,
    CMD_DONE,
    CMD_EVENT,
    CMD_CAL,
    CMD_HELP,
    CMD_VERSION
} CommandType;

static CommandType command;
static NSString *calendar;
static NSString *reminder_id;

static EKEventStore *store;
static NSDictionary *calendars;
static NSDictionary *eventCalendars;
static EKReminder *reminder;
static EKEvent *event;

#define TACKER @"├──"
#define CORNER @"└──"
#define PIPER  @"│  "
#define SPACER @"   "

/*!
    @function my_print
    @abstract Wrapper for fprintf with NSString format
    @param stream
        Output stream to write to
    @param format
        (f)printf style format string
    @param ...
        optional arguments as defined by format string
    @discussion Wraps call to fprintf with an NSString format argument, permitting use of the
        object formatter '%@'
 */
static void my_print(FILE *file, NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *string = [[NSString alloc] initWithFormat:format arguments:args];
    fprintf(file, "%s", [string UTF8String]);
    va_end(args);
}

/*!
    @function my_version
    @abstract Output version information
 */
static void my_version()
{
    my_print(stdout, @"rem Version 0.02 Fairflow\n");
}

/*!
    @function my_usage
    @abstract Output command usage
 */
static void my_usage()
{
    my_print(stdout, @"Usage:\n");
    my_print(stdout, @"\trem <ls> [list]\n");
    my_print(stdout, @"\t\tList reminders\n");
    my_print(stdout, @"\trem rm [list] [reminder]\n");
    my_print(stdout, @"\t\tRemove reminder from list\n");
    my_print(stdout, @"\trem add [reminder]\n");
    my_print(stdout, @"\t\tAdd reminder to your default list\n");
    my_print(stdout, @"\trem cat [list] [item]\n");
    my_print(stdout, @"\t\tShow reminder detail\n");
    my_print(stdout, @"\trem done [list] [item]\n");
    my_print(stdout, @"\t\tMark reminder as complete\n");
    my_print(stdout, @"\trem event [list]\n");
    my_print(stdout, @"\t\tList events\n");
    my_print(stdout, @"\trem help\n");
    my_print(stdout, @"\t\tShow this text\n");
    my_print(stdout, @"\trem version\n");
    my_print(stdout, @"\t\tShow version information\n");
}

/*!
    @function parseArguments
    @abstract Command argument parser
    @description Parse command-line arguments and populate appropriate variables
 */
static void parseArguments()
{
    command = CMD_LS; // default is to list calendars i.e. rem == rem ls
    
    NSMutableArray *args = [NSMutableArray arrayWithArray:[[NSProcessInfo processInfo] arguments]];
    [args removeObjectAtIndex:0];    // pop off application argument
    
    // args array is empty, command was excuted without arguments
    if (args.count == 0)
        return;
    
    NSString *cmd = [args objectAtIndex:0];
    command = (CommandType)[COMMANDS indexOfObject:cmd]; // ulp!
    if (command == CMD_UNKNOWN) {
        my_print(stderr, @"rem: Error unknown command %@", cmd);
        my_usage();
        exit(-1);
    }
    
    // handle help and version requests
    if (command == CMD_HELP) {
        my_usage();
        exit(0);
    }
    else if (command == CMD_VERSION) {
        my_version();
        exit(0);
    }
    
    // if we're adding a reminder, overload reminder_id to hold the reminder text (title)
    if (command == CMD_ADD) {
        reminder_id = [[args subarrayWithRange:NSMakeRange(1, [args count]-1)] componentsJoinedByString:@" "];
        return;
    }

    // get the reminder list (calendar) if exists
    if (args.count >= 2) {
        calendar = [args objectAtIndex:1];
    }

    // get the reminder id if exists // and ignore the rest; note this could be an event id
    if (args.count >= 3) {
        reminder_id = [args objectAtIndex:2];
    }
    
    return;
}

/*!
    @function fetchReminders
    @returns NSArray of EKReminders
    @abstract Fetch all reminders from Event Store
    @description use EventKit API to define a predicate to fetch all reminders from the 
        Event Store. Loop over current Run Loop until asynchronous reminder fetch is 
        completed.
 */
static NSArray* fetchReminders()
{
    __block NSArray *reminders = nil;
    __block BOOL fetching = YES;
    NSPredicate *predicate = [store predicateForRemindersInCalendars:nil];
    [store fetchRemindersMatchingPredicate:predicate completion:^(NSArray *ekReminders) {
        reminders = ekReminders;
        fetching = NO;
    }];

    while (fetching) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    
    return reminders;
}

/*!
    @function days
    @abstract Return the number of seconds in a given number of days
    @returns the number of seconds in the given number of days
    @param d
        integer d representing a number of days
 */
static int days(int d)
{
    return d*24*3600;
}

/*!
 @function fetchEvents
 @returns NSArray of EKEvents
 @abstract Fetch all events from Event Store
 @description use EventKit API to define a predicate to fetch all events from now until 10 days
    from the Event Store.
    No asynchronous fetch at present.
 */
static NSArray* fetchEvents()
{
    __block NSArray *events = nil;
    NSPredicate *predicate =
    [store predicateForEventsWithStartDate:[NSDate dateWithTimeIntervalSinceNow:0.01]
                                   endDate:[NSDate dateWithTimeIntervalSinceNow:days(10)] calendars:nil];
    events = [store eventsMatchingPredicate:(NSPredicate *) predicate];
    return events;
}

/*!
    @function sortReminders
    @abstract Sort an array of reminders into a dictionary.
    @returns NSDictionary
    @param reminders
        NSArray of EKReminder instances
    @description Sort an array of EKReminder instances into a dictionary.
        The keys of the dictionary are reminder list (calendar) names, which is a property of each
        EKReminder. The values are arrays containing EKReminders that share a common calendar.
 */
static NSDictionary* sortReminders(NSArray *reminders)
{
    NSMutableDictionary *results = nil;
    if (reminders != nil && reminders.count > 0) {
        results = [NSMutableDictionary dictionary];
        for (EKReminder *r in reminders) {
            if (r.completed)
                continue;
            
            EKCalendar *calendar = [r calendar];
            if ([results objectForKey:calendar.title] == nil) {
                [results setObject:[NSMutableArray array] forKey:calendar.title];
            }
            NSMutableArray *calendarReminders = [results objectForKey:calendar.title];
            [calendarReminders addObject:r];
        }
    }
    return results;
}

/*!
    @function sortEvents
    @abstract Sort an array of events into a dictionary.
    @returns NSDictionary
    @param events
        NSArray of EKEvent instances
    @description Sort an array of EKEvent instances into a dictionary.
    The keys of the dictionary are event list (calendar) names, which is a property of each
    EKEvent. The values are arrays containing EKEvents that share a common calendar.
 */
static NSDictionary* sortEvents(NSArray *events)
{
    NSMutableDictionary *results = nil;
    if (events != nil && events.count > 0) {
        results = [NSMutableDictionary dictionary];
        for (EKEvent *ev in events) {
            if (ev.allDay) // ignore all day events as a practice run
                continue;
            
            EKCalendar *calendar = [ev calendar];
            if ([results objectForKey:calendar.title] == nil) {
                [results setObject:[NSMutableArray array] forKey:calendar.title];
            }
            NSMutableArray *calendarEvents = [results objectForKey:calendar.title];
            [calendarEvents addObject:ev];
        }
    }
    return results;
}

/*!
    @function validateArguments
    @abstract Verfy the (reminder) list and reminder_id command-line arguments
    @description If provided, verify that the (reminder) list and reminder_id
        command-line arguments are valid. Compare the (reminder) list to the keys
        of the calendars dictionary. Verify the integer value of the reminder_id
        is within the index range of the appropriate calendar array.
 */
static void validateArguments()
// this is called after parsing so dangling arguments are silently ignored
{
    if (command == CMD_LS && calendar == nil)
        return;
    
    if (command == CMD_ADD)
        return;
    
    NSUInteger calendar_id = [[calendars allKeys] indexOfObject:calendar];
    if (calendar_id == NSNotFound) {
        my_print(stderr, @"rem: Error - Unknown Reminder List: \"%@\"\n", calendar);
        exit(-1);
    }
    
    if (command == CMD_LS && reminder_id == nil)
        return;
    
    if (command == CMD_EVENT && reminder_id == nil)
        return; // seems ok
    
    if (command == CMD_CAT && reminder_id == nil)
        return;
    
    NSInteger r_id = [reminder_id integerValue] - 1; // it could be an event_id in fact!
    
    if (command == CMD_CAL)
    {   NSArray *events = [eventCalendars objectForKey:calendar];
        if (r_id < 0 || r_id > events.count-1) {
            my_print(stderr, @"rem: Error - ID Out of Range for Event List: %@\n", calendar);
            exit(-1);
        };
        event = [events objectAtIndex:r_id];
    };

    if (command == CMD_CAT)
    {   NSArray *reminders = [calendars objectForKey:calendar];
        if (r_id < 0 || r_id > reminders.count-1) {
            my_print(stderr, @"rem: Error - ID Out of Range for Reminder List: %@\n", calendar);
            exit(-1);
        };
        reminder = [reminders objectAtIndex:r_id];
    };
}

/*!
    @function my_printCalendarLine
    @abstract format and output line containing calendar (reminder list) name
    @param line
        line to output
    @param last
        is this the last calendar being diplayed?
    @description format and output line containing calendar (reminder list) name.
        If it is the last calendar being displayed, prefix the name with a corner
        unicode character. If it is not the last calendar, prefix the name with a 
        right-tack unicode character. Both prefix unicode characters are followed
        by two horizontal lines, also unicode.
 */
static void my_printCalendarLine(NSString *line, BOOL last)
{
    NSString *prefix = (last) ? CORNER : TACKER;
    my_print(stdout, @"%@ %@\n", prefix, line);
}

/*!
    @function my_printCalendarLine
    @abstract format and output line containing event information
    @param line
        line to output
    @param last
        is this the last reminder being diplayed?
    @param lastCalendar
        does this reminder belong to last calendar being displayed?
    @description format and output line containing reminder information.
        If it is the last reminder being displayed, prefix the name with a corner
        unicode character. If it is not the last reminder, prefix the name with a
        right-tack unicode character. Both prefix unicode characters are followed
        by two horizontal lines, also unicode. Also, indent the reminder with either
        blank space, if part of last calendar; or vertical bar followed by blank space.
 */

static void my_printReminderLine(NSUInteger id, NSString *line, BOOL last, BOOL lastCalendar)
{
    NSString *indent = (lastCalendar) ? SPACER : PIPER;
    NSString *prefix = (last) ? CORNER : TACKER;
    my_print(stdout, @"%@%@ %ld. %@\n", indent, prefix, id, line);
}

/*!
    @function my_listCalendar
    @abstract output a calendar and its reminders // MF or possibly events; headers call an event or reminder an 'item'.
    @param cal
        name of calendar (reminder list)
    @param last
        is this the last calendar being displayed?
    @description given a calendar (reminder list) name, output the calendar via
        my_printCalendarLine. Retrieve the calendars reminders and display via my_printReminderLine.
        Each reminder is prepended with an index/id for other commands
 */
static void my_listCalendar(NSString *cal, BOOL last)
{
    my_printCalendarLine(cal, last);
    NSArray *reminders = [calendars valueForKey:cal];
    for (NSUInteger i = 0; i < reminders.count; i++) {
        EKReminder *r = [reminders objectAtIndex:i];
        my_printReminderLine(i+1, r.title, (r == [reminders lastObject]), last);
    }
}
/*!
 @function my_listEventCalendar
 @abstract output a calendar and its events
 @param cal
 name of calendar (event list)
 @param last
 is this the last calendar being displayed?
 @description given a calendar (reminder list) name, output the calendar via
 my_printCalendarLine. Retrieve the calendar's events and display via my_printReminderLine.
 // should be my_printEventLine now
 Each reminder is prepended with an index/id for other commands
 */

static void my_listEventCalendar(NSString *cal, BOOL last)
{
    my_printCalendarLine(cal, last);
    NSArray *events = [eventCalendars valueForKey:cal];
    for (NSUInteger i = 0; i < events.count; i++) {
        EKEvent *ev = [events objectAtIndex:i];
        my_printReminderLine(i+1, ev.title, (ev == [events lastObject]), last);
    }
}


/*!
    @function listReminders
    @abstract list reminders
    @description list all reminders if no calendar (reminder list) specified,
        or list reminders in specified calendar
 */
static void listReminders()
{
    my_print(stdout, @"Reminders\n");
    if (calendar) {
        my_listCalendar(calendar, YES);
    }
    else {
        for (NSString *cal in calendars) {
            my_listCalendar(cal, (cal == [[calendars allKeys] lastObject]));
        }
    }
}

static void listEvents()
{
    my_print(stdout, @"Events partially implemented\n");
    if (calendar) { /* Just the one calendar parsed; list it */
        my_listEventCalendar(calendar, YES); /* might do something sensible now */
    }
    else {
        for (NSString *cal in eventCalendars) {
            my_listEventCalendar(cal, (cal == [[eventCalendars allKeys] lastObject]));
        }
    }
}

/*!
    @function addReminder
    @abstract add a reminder
    @description add a reminder to the default calendar
 */
static void addReminder()
{
    reminder = [EKReminder reminderWithEventStore:store];
    reminder.calendar = [store defaultCalendarForNewReminders];
    reminder.title = reminder_id;
    
    NSError *error;
    BOOL success = [store saveReminder:reminder commit:YES error:&error];
    if (!success) {
        my_print(stderr, @"rem: Error adding Reminder (%@)\n\t%@", reminder_id, [error localizedDescription]);        
    }
}

/*!
    @function removeReminder
    @abstract remove a specified reminder
    @description remove a specified reminder
 */
static void removeReminder()
{
    NSError *error;
    BOOL success = [store removeReminder:reminder commit:YES error:&error];
    if (!success) {
        my_print(stderr, @"rem: Error removing Reminder (%@) from list %@\n\t%@", reminder_id, calendar, [error localizedDescription]);
    }
}

/*!
    @function showReminder
    @abstract show reminder details
    @description show reminder details: creation date, last modified date (if different than
        creation date), start date (if defined), due date (if defined), notes (if defined)
 */
static void showReminder()
{
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateStyle:NSDateFormatterShortStyle];
   
    my_print(stdout, @"Reminder: %@\n", reminder.title);
    my_print(stdout, @"\tList: %@\n", calendar);
    
    my_print(stdout, @"\tCreated On: %@\n", [dateFormatter stringFromDate:reminder.creationDate]);
        
    if (reminder.lastModifiedDate != reminder.creationDate) {
        my_print(stdout, @"\tLast Modified On: %@\n", [dateFormatter stringFromDate:reminder.lastModifiedDate]);
    }
        
    NSDate *startDate = [reminder.startDateComponents date];
    if (startDate) {
        my_print(stdout, @"\tStarted On: %@\n", [dateFormatter stringFromDate:startDate]);
    }
        
    NSDate *dueDate = [reminder.dueDateComponents date];
    if (dueDate) {
        my_print(stdout, @"\tDue On: %@\n", [dateFormatter stringFromDate:dueDate]);
    }
    
    if (reminder.hasNotes) {
        my_print(stdout, @"\tNotes: %@\n", reminder.notes);
    }
}

/*!
 @function showEvent
 @abstract show event details
 @description show event details: creation date, last modified date (if different than
 creation date), start date (if defined), end date (if defined), notes (if defined)
 */
static void showEvent()
{
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateStyle:NSDateFormatterShortStyle];
    
    my_print(stdout, @"Event: %@\n", event.title);
    my_print(stdout, @"\tList: %@\n", calendar);
    
    my_print(stdout, @"\tCreated On: %@\n", [dateFormatter stringFromDate:event.creationDate]);
    
    if (event.lastModifiedDate >= event.creationDate) {
        my_print(stdout, @"\tLast Modified On: %@\n", [dateFormatter stringFromDate:event.lastModifiedDate]);
    }
    
    NSDate *startDate = event.startDate;
    if (startDate) {
        my_print(stdout, @"\tStarted On: %@\n", [dateFormatter stringFromDate:startDate]);
    }
    
    NSDate *endDate = event.endDate;
    if (endDate) {
        my_print(stdout, @"\tEnds On: %@\n", [dateFormatter stringFromDate:endDate]);
    }
    
    if (event.hasNotes) {
        my_print(stdout, @"\tNotes: %@\n", event.notes);
    }
}

/*!
    @function completeReminder
    @abstract mark specified reminder as complete
    @description mark specified reminder as complete
 */
static void completeReminder()
{
    reminder.completed = YES;
    NSError *error;
    BOOL success = [store saveReminder:reminder commit:YES error:&error];
    if (!success) {
        my_print(stderr, @"rem: Error marking Reminder (%@) from list %@\n\t%@", reminder_id, calendar, [error localizedDescription]);
    }
}

/*!
    @function handleCommand
    @abstract dispatch to correct function based on command-line argument
    @description dispatch to correct function based on command-line argument
 */
static void handleCommand()
{
    switch (command) {
        case CMD_LS:
            listReminders();
            break;
        case CMD_ADD:
            addReminder();
            break;
        case CMD_RM:
            removeReminder();
            break;
        case CMD_CAT:
            showReminder();
            break;
        case CMD_DONE:
            completeReminder();
            break;
        case CMD_EVENT:
            listEvents();
            break;
        case CMD_CAL:
            showEvent();
            break;
        case CMD_HELP:
        case CMD_VERSION:
        case CMD_UNKNOWN:
            break;
    }

}

int main(int argc, const char * argv[])
{

    @autoreleasepool {
        parseArguments();
        
        store = [[EKEventStore alloc] initWithAccessToEntityTypes:EKEntityMaskReminder];
        
        if (command != CMD_ADD) {
            NSArray *reminders = fetchReminders();
            NSArray *events = fetchEvents();
            eventCalendars = sortEvents(events);
            calendars = sortReminders(reminders);
        }
        
        validateArguments();
        handleCommand();
    }
    return 0;
}

