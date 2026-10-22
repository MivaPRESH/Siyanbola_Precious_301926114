# Hotel Reservation System Database Design

## 1. Entities

* **Guest**: Stores contact and identity information for individuals booking or staying at the hotel.
* **Room Category**: Classifies room types (such as Standard, Deluxe, or Suite) and their base pricing.
* **Room**: Represents a physical room in the hotel.
* **Reservation**: Tracks advance room requests made by guests for a specific category and date range.
* **Stay**: Records actual guest stays, room assignments, and check-in/check-out dates.

## 2. Attributes and Keys

* **Guest**
  * `guest_id`: INT, Primary Key (PK), Required.
  * `email`: VARCHAR(255), Unique, Required.
  * `first_name`: VARCHAR(100), Required.
  * `last_name`: VARCHAR(100), Required.

* **Room Category**
  * `category_id`: INT, Primary Key (PK), Required.
  * `category_name`: VARCHAR(50), Unique, Required.

* **Room**
  * `room_number`: VARCHAR(10), Primary Key (PK), Required.
  * `category_id`: INT, Foreign Key (FK) referencing `Room Category(category_id)`, Required.

* **Reservation**
  * `reservation_id`: INT, Primary Key (PK), Required.
  * `guest_id`: INT, Foreign Key (FK) referencing `Guest(guest_id)`, Required.
  * `category_id`: INT, Foreign Key (FK) referencing `Room Category(category_id)`, Required.
  * `check_in_date`: DATE, Required.
  * `check_out_date`: DATE, Required.

* **Stay**
  * `stay_id`: INT, Primary Key (PK), Required.
  * `reservation_id`: INT, Foreign Key (FK) referencing `Reservation(reservation_id)`, Unique, Required.
  * `room_number`: VARCHAR(10), Foreign Key (FK) referencing `Room(room_number)`, Required.
  * `actual_arrival`: TIMESTAMP, Required.
  * `actual_departure`: TIMESTAMP, Optional (null until check-out).

## 3. Relationships

* **Guest to Reservation**: A guest can make zero, one, or many reservations. Each reservation belongs to exactly one guest.
* **Room Category to Room**: A room category contains zero, one, or many physical rooms. Each physical room belongs to exactly one room category.
* **Room Category to Reservation**: A room category can be referenced by zero, one, or many reservations. Each reservation requests exactly one room category.
* **Guest to Stay**: A guest links to stays through reservations. A stay belongs to exactly one reservation, which in turn belongs to exactly one guest.
* **Room to Stay**: A room can have zero, one, or many historical stay records, but at most one active stay at a time. Each stay record is assigned to exactly one physical room.
* **Reservation to Stay**: A reservation can have zero or one stay record (a booking might be canceled or not yet checked in). Each stay record links to exactly one reservation.

## 4. Business Rules and Constraints

* **Rule 1 (Unique guest ID and email)**: Enforced by the `PRIMARY KEY` on `guest_id` and a `UNIQUE` constraint on `email`.
* **Rule 2 (Unique room number and category linking)**: Enforced by the `PRIMARY KEY` on `room_number` and a `FOREIGN KEY` (`category_id`) referencing `Room Category`.
* **Rule 3 (Reservation references guest and category)**: Enforced by `FOREIGN KEY` constraints on `guest_id` and `category_id` in `Reservation`.
* **Rule 4 (No overlapping active check-ins for a room)**: Enforced by a database exclusion constraint or application-level trigger checking that no two active stay records (where `actual_departure` is null) share the same `room_number`.
* **Rule 5 (No overlapping guest reservations)**: Enforced by a database exclusion constraint or check procedure preventing overlapping `[check_in_date, check_out_date)` ranges for the same `guest_id`.
* **Rule 6 (Check-out date later than check-in date)**: Enforced by a `CHECK (check_out_date > check_in_date)` constraint on `Reservation`.
* **Rule 7 (Actual departure date rules)**: `actual_departure` defaults to `NULL`. Enforced by a `CHECK (actual_departure >= actual_arrival)` constraint on `Stay`.
* **Rule 8 (Completed check-out rules)**: Enforced by application logic preventing updates to `actual_departure` once populated, ensuring a stay is checked out only once while preserving the row.

## 5. Design Assumptions

* I chose to separate `Reservation` and `Stay` into distinct entities because a guest reserves a room category in advance, but staff assigns a specific physical `room_number` only upon arrival.