# Hotel Reservation System Normalisation

Normalisation separates information into related tables to reduce repeated details and avoid inconsistent updates\. The same two guests and three stays are used below\. Only the fields needed to explain the changes are shown; the full design keeps the other fields from the design document\.

Dates are shortened for readability\. `actual_arrival` represents the full check\-in date and time\. Names and emails are fictional\.

## Starting Reservation and Stay List

|guest_id|full_name    |email            |Reservations and Stays                                                                                                                                                                    |
|-------:|-------------|-----------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|1       |Clara Oswald |clara@example.com|Category 1, Deluxe, $150; Res 101 (2026-11-01 to 2026-11-05); Stay 10, Room 201, Arrived 2026-11-01 14:00; Res 102 (2026-12-01 to 2026-12-05); Stay 11, Room 202, Arrived 2026-12-01 15:00|
|2       |David Tennant|david@example.com|Category 1, Deluxe, $150; Res 103 (2026-11-10 to 2026-11-12); Stay 12, Room 201, Arrived 2026-11-10 14:30                                                                                 |

The first row contains multiple reservations and stays inside a single cell\. Finding a specific booking, updating guest details, or processing a check\-out is awkward\.

## 1NF: One Value per Cell

First Normal Form &#40;1NF&#41; requires every cell to contain a single, atomic value, eliminating repeating groups\.

|guest_id|full_name    |email            |category_id|category_name|reservation_id|check_in_date|check_out_date|stay_id|room_number|actual_arrival  |
|-------:|-------------|-----------------|----------:|-------------|-------------:|-------------|--------------|------:|----------:|----------------|
|1       |Clara Oswald |clara@example.com|1          |Deluxe       |101           |2026-11-01   |2026-11-05    |10     |201        |2026-11-01 14:00|
|1       |Clara Oswald |clara@example.com|1          |Deluxe       |102           |2026-12-01   |2026-12-05    |11     |202        |2026-12-01 15:00|
|2       |David Tennant|david@example.com|1          |Deluxe       |103           |2026-11-10   |2026-11-12    |12     |201        |2026-11-10 14:30|

**Key:** `(guest_id, reservation_id)`

**Explanation:** Each booking has its own row\. The repeated list is removed\. However, data like guest names, emails, and category details repeat across multiple rows, creating redundant storage and update risks\.

## 2NF: Details Depend on the Whole Key

Second Normal Form &#40;2NF&#41; includes 1NF and requires that all non\-key attributes depend on the entire primary key, not just part of it &#40;no partial dependencies&#41;\.

In our 1NF table with the composite key `(guest_id, reservation_id)`:

- `full_name` and `email` depend only on `guest_id` &#40;part of the key&#41;\.
- `category_id`, `category_name`, `check_in_date`, `check_out_date`, `stay_id`, `room_number`, and `actual_arrival` depend on `reservation_id`\.

To reach 2NF, we split the data into tables where attributes depend on the full primary key of each respective table\.

### Guest Details

**Key:** `guest_id`

|guest_id|full_name    |email            |
|-------:|-------------|-----------------|
|1       |Clara Oswald |clara@example.com|
|2       |David Tennant|david@example.com|

### Reservation and Stay Details

**Key:** `reservation_id` &#40;`guest_id` acts as a Foreign Key to Guest&#41;

|reservation_id|guest_id|category_id|category_name|check_in_date|check_out_date|stay_id|room_number|actual_arrival  |
|-------------:|-------:|----------:|-------------|-------------|--------------|------:|----------:|----------------|
|101           |1       |1          |Deluxe       |2026-11-01   |2026-11-05    |10     |201        |2026-11-01 14:00|
|102           |1       |1          |Deluxe       |2026-12-01   |2026-12-05    |11     |202        |2026-12-01 15:00|
|103           |2       |1          |Deluxe       |2026-11-10   |2026-11-12    |12     |201        |2026-11-10 14:30|

**Explanation:** Guest information is separated, removing duplicate guest records\. However, `category_name` still depends on `category_id` &#40;not `reservation_id`&#41;, and stay details depend on `stay_id`\.

## 3NF: Keep Details with the Thing They Describe

Third Normal Form &#40;3NF&#41; includes 2NF and requires that no non\-key attribute depends on another non\-key attribute &#40;no transitive dependencies&#41;\.

Two transitive dependencies exist in the 2NF tables:

1. `category_id` determines `category_name`: category names describe the category, not the reservation\.
2. `stay_id` determines `room_number` and `actual_arrival`: stay details represent an actual check\-in event separate from advance reservation requests\.
3. `room_number` determines its `category_id`: physical rooms belong to a category independently of stays or reservations\.

### Guest

**Key:** `guest_id`

|guest_id|full_name    |email            |
|-------:|-------------|-----------------|
|1       |Clara Oswald |clara@example.com|
|2       |David Tennant|david@example.com|

### Room Category

**Key:** `category_id`

|category_id|category_name|
|----------:|-------------|
|1          |Deluxe       |

### Room

**Key:** `room_number` &#40;`category_id` is a Foreign Key to Room Category&#41;

|room_number|category_id|
|----------:|----------:|
|201        |1          |
|202        |1          |

### Reservation

**Key:** `reservation_id` &#40;`guest_id` and `category_id` are Foreign Keys&#41;

|reservation_id|guest_id|category_id|check_in_date|check_out_date|
|-------------:|-------:|----------:|-------------|--------------|
|101           |1       |1          |2026-11-01   |2026-11-05    |
|102           |1       |1          |2026-12-01   |2026-12-05    |
|103           |2       |1          |2026-11-10   |2026-11-12    |

### Stay

**Key:** `stay_id` &#40;`reservation_id` and `room_number` are Foreign Keys&#41;

|stay_id|reservation_id|room_number|actual_arrival  |
|------:|-------------:|----------:|----------------|
|10     |101           |201        |2026-11-01 14:00|
|11     |102           |202        |2026-12-01 15:00|
|12     |103           |201        |2026-11-10 14:30|

**Explanation:** Each entity now stores only the fields directly describing its primary key\. Foreign key IDs &#40;`guest_id`, `category_id`, `reservation_id`, `room_number`&#41; preserve relationships across tables without repeating descriptive text\.

## Final Design Notes

The five tables produced by 3NF match the agreed database design\.

- **Fields omitted for visual clarity in examples:** `first_name` and `last_name` were combined as `full_name`; `actual_departure` was omitted &#40;defaults to `NULL`&#41;\.
- **Surrogate Primary Keys:** `guest_id`, `reservation_id`, `category_id`, and `stay_id` are system\-generated unique identifiers\. Using single\-column integer primary keys simplifies table linking and improves database performance, but the 3NF structure is achieved by ensuring zero functional dependencies between non\-key fields\.
- **Constraints:** Normalisation structures data efficiently but does not enforce business rules on its own\. Database constraints &#40;e\.g\., `CHECK (check_out_date > check_in_date)`, exclusion constraints on overlapping dates, and `UNIQUE` constraints&#41; remain necessary to maintain full domain integrity\.