"""Build a four-page PBIP/PBIR report and an import semantic model from SQL views."""
import json
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src'))
from companyx.config import ROOT, load_config

cfg=load_config()
out=ROOT/'powerbi'
report=out/'CompanyX.Report'
model=out/'CompanyX.SemanticModel'
base='https://developer.microsoft.com/json-schemas/fabric/item/report/'


def write(path,data):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(data,indent=2,ensure_ascii=False),encoding='utf-8')


def table(name,schema,item,columns):
    cols=[]
    for col,typ in columns.items():
        entry={'name':col,'dataType':typ,'sourceColumn':col,'summarizeBy':'none'}
        if typ=='dateTime': entry['formatString']='dd MMM yyyy'
        if col.endswith('Key') or col.endswith('ID'): entry['isHidden']=True
        cols.append(entry)
    return {'name':name,'columns':cols,'partitions':[{'name':name,'mode':'import','source':{'type':'m',
        'expression':['let',f'    Source = Sql.Database({json.dumps(cfg["server"])}, {json.dumps(cfg["warehouse_database"])}, [CreateNavigationProperties=false]),',
                      f'    Data = Source{{[Schema="{schema}",Item="{item}"]}}[Data],',
                      '    Selected = Table.SelectColumns(Data, {'+', '.join(json.dumps(c) for c in columns)+'})',
                      'in','    Selected']}}]}


tables=[
 table('FactSales','mart','Sales',dict(SalesOrderDetailID='int64',SalesOrderID='int64',SalesDateKey='int64',ProductKey='int64',CustomerKey='int64',SalesPersonKey='int64',TerritoryKey='int64',PromotionKey='int64',OrderQty='int64',NetSales='double',EstimatedCost='double',EstimatedGrossProfit='double')),
 table('DimDate','dw','DimDate',dict(DateKey='int64',Date='dateTime',Year='int64',Quarter='int64',Month='int64',MonthName='string',YearMonth='string',WeekStart='dateTime',ISOWeek='int64',ISOYear='int64')),
 table('DimProduct','dw','DimProduct',dict(ProductKey='int64',ProductID='int64',ProductName='string',Category='string',Subcategory='string',IsCurrent='boolean')),
 table('DimCustomer','dw','DimCustomer',dict(CustomerKey='int64',CustomerID='int64',CustomerType='string')),
 table('DimSalesPerson','dw','DimSalesPerson',dict(SalesPersonKey='int64',SalesPersonID='int64',SalesPersonName='string')),
 table('DimTerritory','dw','DimTerritory',dict(TerritoryKey='int64',TerritoryID='int64',TerritoryName='string',CountryRegionCode='string',TerritoryGroup='string')),
 table('DimPromotion','dw','DimPromotion',dict(PromotionKey='int64',SpecialOfferID='int64',Description='string')),
 table('Forecast','mart','LatestForecast',dict(ForecastRunKey='int64',WeekStart='dateTime',Horizon='int64',PredictedSales='double',LowerBound='double',UpperBound='double',Champion='string',ForecastOriginDate='dateTime',ReleaseStatus='string',CreatedAt='dateTime')),
 table('ForecastChart','mart','ForecastChart',dict(WeekStart='dateTime',ActualSales='double',PredictedSales='double',LowerBound='double',UpperBound='double')),
 table('ModelEvaluation','mart','LatestModelEvaluation',dict(ModelName='string',EvaluationSet='string',MAE='double',RMSE='double',WMAPE='double',Bias='double',IntervalCoverage='double',N='int64')),
 table('Backtest','mart','LatestBacktest',dict(ModelName='string',EvaluationSet='string',TargetDate='dateTime',Actual='double',Predicted='double',LowerBound='double',UpperBound='double')),
 table('ETLBatch','ctl','Batch',dict(BatchID='int64',StartedAt='dateTime',FinishedAt='dateTime',Status='string',RowsRead='int64',RowsInserted='int64',RowsUpdated='int64',RowsRejected='int64')),
 table('Quarantine','ctl','RejectedSales',dict(SalesOrderDetailID='int64',Reason='string')),
]
measures={
 'FactSales':{
  'Net Sales':('SUM(FactSales[NetSales])','#,0.00'),
  'Quantity':('SUM(FactSales[OrderQty])','#,0'),
  'Total Orders':('DISTINCTCOUNT(FactSales[SalesOrderID])','#,0'),
  'AOV':('DIVIDE([Net Sales],[Total Orders])','#,0.00'),
  'ASP':('DIVIDE([Net Sales],[Quantity])','#,0.00'),
  'Estimated Gross Profit':('SUM(FactSales[EstimatedGrossProfit])','#,0.00'),
  'Cost Covered Sales':('CALCULATE([Net Sales],FILTER(FactSales,NOT ISBLANK(FactSales[EstimatedCost])))','#,0.00'),
  'Estimated Margin':('DIVIDE([Estimated Gross Profit],[Cost Covered Sales])','0.0%'),
  'Cost Coverage':('DIVIDE([Cost Covered Sales],[Net Sales])','0.0%'),
  'Sales Previous Year':('CALCULATE([Net Sales],DATEADD(DimDate[Date],-1,YEAR))','#,0.00'),
  'YoY Growth':('DIVIDE([Net Sales]-[Sales Previous Year],[Sales Previous Year])','0.0%'),
  'Sales Previous Month':('CALCULATE([Net Sales],DATEADD(DimDate[Date],-1,MONTH))','#,0.00'),
  'MoM Growth':('DIVIDE([Net Sales]-[Sales Previous Month],[Sales Previous Month])','0.0%'),
 },
 'ForecastChart':{name:(f'SUM(ForecastChart[{col}])','#,0.00') for name,col in [('Actual Sales','ActualSales'),('Forecast Sales','PredictedSales'),('Lower 80%','LowerBound'),('Upper 80%','UpperBound')]},
 'Forecast':{
  'Model Status':('SELECTEDVALUE(Forecast[ReleaseStatus],"NO FORECAST")',''),
  'Champion':('SELECTEDVALUE(Forecast[Champion],"NO MODEL")',''),
  'Forecast Origin':('MAX(Forecast[ForecastOriginDate])','dd MMM yyyy'),
  'Eight Week Forecast':('SUM(Forecast[PredictedSales])','#,0.00'),
  'Planning Guidance':('IF([Model Status]="REVIEW_REQUIRED","Review model and sales history before changing plans","Review forecast with the sales planning team")',''),
 },
 'ModelEvaluation':{
  'Holdout wMAPE':('CALCULATE(MAX(ModelEvaluation[WMAPE]),ModelEvaluation[EvaluationSet]="holdout")','0.0%'),
  'Holdout Coverage':('CALCULATE(MAX(ModelEvaluation[IntervalCoverage]),ModelEvaluation[EvaluationSet]="holdout")','0.0%'),
  'Holdout Bias':('CALCULATE(MAX(ModelEvaluation[Bias]),ModelEvaluation[EvaluationSet]="holdout")','0.0%'),
 },
 'Quarantine':{'Rejected Lines':('COUNTROWS(Quarantine)','#,0')},
 'ETLBatch':{'Last Successful ETL':('CALCULATE(MAX(ETLBatch[FinishedAt]),ETLBatch[Status]="SUCCESS")','dd MMM yyyy HH:mm')},
}
for t in tables:
    if t['name'] in measures:
        t['measures']=[dict(name=n,expression=e,formatString=f) for n,(e,f) in measures[t['name']].items()]
    if t['name']=='DimDate':
        t['dataCategory']='Time'
        for c in t['columns']:
            if c['name']=='Date': c['isKey']=True
            if c['name']=='MonthName': c['sortByColumn']='Month'

relationships=[]
for dim,key,fact_key in [('DimDate','DateKey','SalesDateKey'),('DimProduct','ProductKey','ProductKey'),('DimCustomer','CustomerKey','CustomerKey'),('DimSalesPerson','SalesPersonKey','SalesPersonKey'),('DimTerritory','TerritoryKey','TerritoryKey'),('DimPromotion','PromotionKey','PromotionKey')]:
    relationships.append(dict(name='FactSales_'+dim,fromTable='FactSales',fromColumn=fact_key,toTable=dim,toColumn=key,
                              fromCardinality='many',toCardinality='one',crossFilteringBehavior='oneDirection',isActive=True))

write(model/'definition.pbism',{'$schema':'https://developer.microsoft.com/json-schemas/fabric/item/semanticModel/definitionProperties/1.0.0/schema.json','version':'1.0','settings':{}})
write(model/'model.bim',{'name':'CompanyX','compatibilityLevel':1600,'model':{'culture':'en-US','defaultPowerBIDataSourceVersion':'powerBI_V3',
      'tables':tables,'relationships':relationships,'annotations':[{'name':'__PBI_TimeIntelligenceEnabled','value':'0'}]}})
write(out/'CompanyX.pbip',{'version':'1.0','artifacts':[{'report':{'path':'CompanyX.Report'}}],'settings':{'enableAutoRecovery':True}})
write(report/'definition.pbir',{'$schema':base+'definitionProperties/2.0.0/schema.json','version':'4.0','datasetReference':{'byPath':{'path':'../CompanyX.SemanticModel'}}})
write(report/'definition/version.json',{'$schema':base+'definition/versionMetadata/1.0.0/schema.json','version':'2.0.0'})
write(report/'definition/report.json',{'$schema':base+'definition/report/3.3.0/schema.json','themeCollection':{},'settings':{'useStylableVisualContainerHeader':True,'exportDataMode':'AllowSummarized'}})
write(out/'theme.json',{'name':'CompanyX','dataColors':['#145C73','#F4A259','#64748B','#89B6A5','#9A5C73'],'background':'#F5F7FA','foreground':'#183042','tableAccent':'#145C73','textClasses':{'title':{'fontFace':'Segoe UI Semibold'},'label':{'fontFace':'Segoe UI'}}})


def literal(text): return {'expr':{'Literal':{'Value':"'"+text.replace("'","''")+"'"}}}


def field(entity,prop,measure=False):
    return {('Measure' if measure else 'Column'):{'Expression':{'SourceRef':{'Entity':entity}},'Property':prop}}


def projection(entity,prop,measure=False):
    return {'field':field(entity,prop,measure),'queryRef':entity+'.'+prop,'nativeQueryRef':prop}


page_names=[]


def page(name,title):
    page_names.append(name)
    p=report/'definition/pages'/name
    write(p/'page.json',{'$schema':base+'definition/page/2.1.0/schema.json','name':name,'displayName':title,'displayOption':'FitToPage','height':800,'width':1280})
    return p


def visual(p,name,kind,title,x,y,w,h,roles):
    data={'$schema':base+'definition/visualContainer/2.9.0/schema.json','name':name,
          'position':{'x':x,'y':y,'z':0,'height':h,'width':w,'tabOrder':0},
          'visual':{'visualType':kind,'query':{'queryState':{role:{'projections':projs} for role,projs in roles.items()}},
                    'visualContainerObjects':{'title':[{'properties':{'show':{'expr':{'Literal':{'Value':'true'}}},'text':literal(title)}}]},
                    'drillFilterOtherVisuals':True}}
    write(p/'visuals'/name/'visual.json',data)


def text(p,name,content,x,y,w,h,size='12pt'):
    write(p/'visuals'/name/'visual.json',{'$schema':base+'definition/visualContainer/2.9.0/schema.json','name':name,
      'position':{'x':x,'y':y,'z':0,'width':w,'height':h,'tabOrder':0},'visual':{'visualType':'textbox','objects':{
      'general':[{'properties':{'paragraphs':[{'textRuns':[{'value':content,'textStyle':{'fontSize':size,'fontFamily':'Segoe UI'}}]}]}}]}}})


def card(p,name,entity,measure,x,y=90,w=195,title=None):
    visual(p,name,'card',title or measure,x,y,w,120,{'Values':[projection(entity,measure,True)]})


p=page('Executive','01 | Executive sales')
text(p,'heading','COMPANYX  /  SALES INTELLIGENCE',24,12,1000,44,'24pt')
text(p,'subtitle','Shipped orders · validated sales lines · historical backup, 2011–2014 · source monetary units',24,57,1220,30)
for i,m in enumerate(['Net Sales','Total Orders','Quantity','AOV','Estimated Gross Profit','Cost Coverage']): card(p,'kpi'+str(i),'FactSales',m,24+i*206)
visual(p,'trend','lineChart','Monthly net sales',24,230,800,330,{'Category':[projection('DimDate','YearMonth')],'Y':[projection('FactSales','Net Sales',True)]})
visual(p,'category','clusteredBarChart','Category contribution',844,230,410,330,{'Category':[projection('DimProduct','Category')],'Y':[projection('FactSales','Net Sales',True)]})
visual(p,'year','slicer','Year',24,590,300,160,{'Values':[projection('DimDate','Year')]})
card(p,'margin','FactSales','Estimated Margin',350,590,270)
card(p,'dq','Quarantine','Rejected Lines',640,590,270)
card(p,'refresh','ETLBatch','Last Successful ETL',930,590,324)

p=page('Trends','02 | Trends and seasonality')
text(p,'heading','SALES TREND & SEASONALITY',24,12,1220,44,'24pt')
text(p,'subtitle','Use a year/month selection to compare like-for-like periods. Historical actuals only.',24,57,1220,30)
card(p,'sales','FactSales','Net Sales',24,90,275)
card(p,'yoy','FactSales','YoY Growth',320,90,275)
card(p,'mom','FactSales','MoM Growth',616,90,275)
visual(p,'year','slicer','Year',912,90,340,120,{'Values':[projection('DimDate','Year')]})
visual(p,'weekly','lineChart','Weekly net sales (partial edge weeks visible in historical analysis)',24,230,1230,290,{'Category':[projection('DimDate','WeekStart')],'Y':[projection('FactSales','Net Sales',True)]})
visual(p,'season','clusteredColumnChart','Month-of-year pattern',24,550,790,220,{'Category':[projection('DimDate','MonthName')],'Y':[projection('FactSales','Net Sales',True)],'Series':[projection('DimDate','Year')]})
visual(p,'category','slicer','Category',844,550,410,220,{'Values':[projection('DimProduct','Category')]})

p=page('Performance','03 | Product and territory')
text(p,'heading','PRODUCT / TERRITORY PERFORMANCE',24,12,1220,44,'24pt')
text(p,'subtitle','Historical dimension versions · estimated standard-cost margin · orders use DISTINCTCOUNT',24,57,1220,30)
visual(p,'territory','clusteredBarChart','Net sales by territory',24,100,600,300,{'Category':[projection('DimTerritory','TerritoryName')],'Y':[projection('FactSales','Net Sales',True)]})
visual(p,'salesperson','clusteredBarChart','Net sales by salesperson',654,100,600,300,{'Category':[projection('DimSalesPerson','SalesPersonName')],'Y':[projection('FactSales','Net Sales',True)]})
visual(p,'products','tableEx','Product detail',24,430,920,335,{'Values':[projection('DimProduct','Category'),projection('DimProduct','ProductName'),projection('FactSales','Net Sales',True),projection('FactSales','Quantity',True),projection('FactSales','Estimated Margin',True)]})
visual(p,'territoryfilter','slicer','Territory',974,430,280,160,{'Values':[projection('DimTerritory','TerritoryName')]})
visual(p,'categoryfilter','slicer','Category',974,605,280,160,{'Values':[projection('DimProduct','Category')]})

p=page('Forecast','04 | Forecast and decisions')
text(p,'heading','FORECAST & DECISION CENTER',24,12,1220,44,'24pt')
text(p,'subtitle','TOTAL SALES ONLY · 8 weeks from the last complete historical week · no product/territory forecast filters',24,57,1220,30)
card(p,'status','Forecast','Model Status',24,90,285)
card(p,'model','Forecast','Champion',330,90,200)
card(p,'origin','Forecast','Forecast Origin',550,90,230)
card(p,'wmape','ModelEvaluation','Holdout wMAPE',800,90,225)
card(p,'coverage','ModelEvaluation','Holdout Coverage',1045,90,210)
visual(p,'forecastchart','lineChart','Actual / forecast / approximate 80% lower and upper bounds',24,230,795,310,{'Category':[projection('ForecastChart','WeekStart')],'Y':[projection('ForecastChart',m,True) for m in ['Actual Sales','Forecast Sales','Lower 80%','Upper 80%']]})
visual(p,'predictions','tableEx','Eight-week forecast',839,230,415,310,{'Values':[projection('Forecast','WeekStart'),projection('Forecast','PredictedSales'),projection('Forecast','LowerBound'),projection('Forecast','UpperBound')]})
visual(p,'metrics','tableEx','Validation selects the model; holdout evaluates it',24,570,795,195,{'Values':[projection('ModelEvaluation',c) for c in ['ModelName','EvaluationSet','WMAPE','Bias','IntervalCoverage']]})
text(p,'decision','Decision: review model errors and recent sales before changing the sales plan. Revenue forecasts alone cannot determine SKU replenishment quantities; stock, lead time and unit demand are needed.',839,570,415,195,'15pt')
write(report/'definition/pages/pages.json',{'$schema':base+'definition/pagesMetadata/1.0.0/schema.json','pageOrder':page_names,'activePageName':'Executive'})
(out/'measures.dax').write_text('\n\n'.join(f"-- {t}\n{n} = {e}" for t,items in measures.items() for n,(e,f) in items.items()),encoding='utf-8')
print(f'Generated {len(tables)} tables, {len(relationships)} relationships and {len(page_names)} pages.')
