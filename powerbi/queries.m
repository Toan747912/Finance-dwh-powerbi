// ===================================================================
// 9 query nap bang dwh.* vao Power BI. Moi khoi "let ... in ..." la 1 query RIENG.
// Cach dung: Home > Transform data > New Source > Blank Query > Advanced Editor > dan 1 khoi > Done > doi ten query
// (ten query = ten bang, vd dim_date). Can 2 Parameter truoc: ServerName, DatabaseName (xem docs/powerbi_guide.md).
// ===================================================================

// ---- query: dim_date
let
    Source = Sql.Database(ServerName, DatabaseName),
    T = Source{[Schema = "dwh", Item = "dim_date"]}[Data]
in
    T

// ---- query: dim_product
let
    Source = Sql.Database(ServerName, DatabaseName),
    T = Source{[Schema = "dwh", Item = "dim_product"]}[Data]
in
    T

// ---- query: dim_customer
let
    Source = Sql.Database(ServerName, DatabaseName),
    T = Source{[Schema = "dwh", Item = "dim_customer"]}[Data]
in
    T

// ---- query: dim_territory
let
    Source = Sql.Database(ServerName, DatabaseName),
    T = Source{[Schema = "dwh", Item = "dim_territory"]}[Data]
in
    T

// ---- query: dim_salesperson
let
    Source = Sql.Database(ServerName, DatabaseName),
    T = Source{[Schema = "dwh", Item = "dim_salesperson"]}[Data]
in
    T

// ---- query: dim_vendor
let
    Source = Sql.Database(ServerName, DatabaseName),
    T = Source{[Schema = "dwh", Item = "dim_vendor"]}[Data]
in
    T

// ---- query: fact_sales
let
    Source = Sql.Database(ServerName, DatabaseName),
    T = Source{[Schema = "dwh", Item = "fact_sales"]}[Data]
in
    T

// ---- query: fact_purchasing
let
    Source = Sql.Database(ServerName, DatabaseName),
    T = Source{[Schema = "dwh", Item = "fact_purchasing"]}[Data]
in
    T

// ---- query: fact_quota
let
    Source = Sql.Database(ServerName, DatabaseName),
    T = Source{[Schema = "dwh", Item = "fact_quota"]}[Data]
in
    T
