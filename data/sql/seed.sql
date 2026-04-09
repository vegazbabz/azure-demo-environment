-- ─────────────────────────────────────────────────────────────────────────────
-- ADE Demo Data — SQL seed script
-- Targets: AdventureWorksLT (deployed as sample DB by databases.bicep)
-- Run manually or via seed-data.ps1 after deployment.
-- ─────────────────────────────────────────────────────────────────────────────

USE [AdventureWorksLT];
GO

-- Insert demo customers (SalesLT.Customer)
-- Only inserts if FirstName doesn't already exist to make the script idempotent
IF NOT EXISTS (SELECT 1 FROM SalesLT.Customer WHERE FirstName = 'Alex' AND LastName = 'Azure')
BEGIN
    INSERT INTO SalesLT.Customer (FirstName, LastName, EmailAddress, CompanyName, SalesPerson, PasswordHash, PasswordSalt, rowguid, ModifiedDate)
    VALUES
      ('Alex',     'Azure',   'alex.azure@contoso.example',    'Contoso Ltd',       'adventure-works\pamela0', 'AQAAAAEAACcQAAAAEA==', 'U2FsdA==', NEWID(), GETDATE()),
      ('Blake',    'Bicep',   'blake.bicep@fabrikam.example',  'Fabrikam Inc',      'adventure-works\jillian0', 'AQAAAAEAACcQAAAAEA==', 'U2FsdA==', NEWID(), GETDATE()),
      ('Charlie',  'Cloud',   'charlie@northwind.example',     'Northwind Traders', 'adventure-works\jose1',   'AQAAAAEAACcQAAAAEA==', 'U2FsdA==', NEWID(), GETDATE()),
      ('Dana',     'DevOps',  'dana@adventureworks.example',   'Adventure Works',   'adventure-works\shu0',    'AQAAAAEAACcQAAAAEA==', 'U2FsdA==', NEWID(), GETDATE());
END
GO

-- Summary query — useful for verifying the seed
SELECT
    c.CustomerID,
    c.FirstName + ' ' + c.LastName AS FullName,
    c.CompanyName,
    c.EmailAddress,
    COUNT(soh.SalesOrderID) AS OrderCount,
    ISNULL(SUM(soh.TotalDue), 0)  AS TotalRevenue
FROM SalesLT.Customer c
LEFT JOIN SalesLT.SalesOrderHeader soh ON c.CustomerID = soh.CustomerID
GROUP BY c.CustomerID, c.FirstName, c.LastName, c.CompanyName, c.EmailAddress
ORDER BY TotalRevenue DESC;
GO
