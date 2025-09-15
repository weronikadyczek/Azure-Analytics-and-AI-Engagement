
CREATE VIEW SalesLT.MostSoldProduct AS
SELECT TOP 1 p.ProductID, p.Name, SUM(sod.OrderQty) AS TotalSold
FROM SalesLT.SalesOrderDetail sod
JOIN SalesLT.Product p ON sod.ProductID = p.ProductID
GROUP BY p.ProductID, p.Name
ORDER BY TotalSold DESC;

GO

