# Portfolio 1 Database Design and Modelling

## Case study
A hotel reservation system manages guest records, room categories, physical rooms, and stay bookings. Desk staff process room allocations and guest check-ins, while guests make advance reservations for available rooms. Desk staff can check room availability, review reservation statuses, and track active guest stays.

## Users
Guests search for rooms and make reservation requests. Hotel desk staff manage guest profiles, update room listings, assign physical rooms, handle check-ins and check-outs, and monitor upcoming reservations.

## Main operations
Create a guest profile; register a room category and individual rooms; place a room reservation; check room availability by date range; perform guest check-in with room assignment; record a check-out; view active reservations and stay history.

## Business rules
1. Each guest has a unique guest identifier and a unique email address.
2. Each room has a unique room number and belongs to one room category, while a category contains multiple rooms.
3. Each reservation refers to one existing guest and one existing room category.
4. A room can have at most one active check-in during any given date range.
5. A guest can make multiple reservations, provided the stay dates for each booking do not overlap.
6. The scheduled check-out date must be later than the check-in date. Desk staff specify both dates upon booking creation.
7. The actual departure date remains empty until check-out and cannot precede the actual arrival date.
8. A completed check-out closes an active stay record without removing its transaction history, and a stay can be checked out only once.

## Scope
One hotel location using fictional records for room management and stay bookings. Online payment processing, billing line items, room service orders, housekeeping schedules, and user authentication are outside the scope of this database.
